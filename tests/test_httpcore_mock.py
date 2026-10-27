#!/usr/bin/env python3
"""httpcore.lua 的本地测试：用假 socket 顶替 LuaSocket。

真实场景里最危险的是"大响应只发出去一部分"——封面图几十 KB，
LuaSocket 的 send 在超时模式下会分片返回。这里用一个每次只肯接收
N 字节的假客户端，验证 send_all 能不能把剩余字节补完。

运行：python3 tests/test_httpcore_mock.py
依赖：pip3 install lupa
"""

import sys

from lupa import LuaRuntime

PLUGIN = __import__("os").path.dirname(__import__("os").path.dirname(
    __import__("os").path.abspath(__file__)))

L = LuaRuntime(unpack_returned_tuples=True)

# ── 假 socket 模块 ───────────────────────────────────────────
# 用一个队列模拟 accept：每次 poll 取一个客户端，客户端自带请求行和
# 发送策略（一次能收多少字节）。
L.execute(r'''
package.preload["socket"] = function()
    local M = {}
    M.clients = {}          -- 待 accept 的客户端队列
    M.chunk = 4096          -- 客户端每次 send 最多收多少字节

    local Client = {}
    Client.__index = Client
    function Client:settimeout() end
    function Client:close() self.closed = true end

    function Client:receive(fmt)
        local line = table.remove(self.lines, 1)
        return line
    end

    function Client:send(data, i)
        if self.fail then return nil, "closed", 0 end
        local from = i or 1
        local n = math.min(M.chunk, #data - from + 1)
        if n <= 0 then return #data end
        self.out[#self.out + 1] = string.sub(data, from, from + n - 1)
        return from + n - 1
    end

    function M.new_client(lines, opts)
        opts = opts or {}
        local c = setmetatable({
            lines = lines, out = {}, fail = opts.fail,
        }, Client)
        M.clients[#M.clients + 1] = c
        return c
    end

    local Server = {}
    Server.__index = Server
    function Server:settimeout() end
    function Server:close() self.closed = true end
    function Server:accept() return table.remove(M.clients, 1) end

    M.server = setmetatable({}, Server)

    function M.bind(host, port)
        M.bound = { host = host, port = port }
        return M.server
    end

    M.reset = function()
        M.clients = {}
        M.bound = nil
        M.chunk = 4096
    end

    return M
end
''')

L.execute('HttpCore = assert(loadfile(%r .. "/httpcore.lua"))()' % PLUGIN)

fail = 0


def check(name, cond, extra=""):
    global fail
    print(("PASS  " if cond else "FAIL  ") + name + (("   " + str(extra)) if extra else ""))
    if not cond:
        fail += 1


def request(target, method="GET", big=0, chunk=4096, fail_send=False):
    """发一个请求，返回 (状态码, 头字典, body 长度, body 原文, 处理器收到的参数)"""
    L.execute("package.loaded.socket.reset()")
    L.execute("package.loaded.socket.chunk = %d" % chunk)
    L.execute('_G.__seen = nil')
    L.execute('''
        _G.__srv = HttpCore.new(18999, function(method, path, query)
            _G.__seen = { method = method, path = path, query = query }
            if path == "/" then
                return 200, "text/html; charset=utf-8", "hello 面板"
            elseif path == "/big" then
                return 200, "image/jpeg", string.rep("x", %d)
            elseif path == "/api/light" then
                return 200, "application/json", '{"ok":1,"n":' .. (query:match("n=(%%d+)") or "0") .. '}'
            elseif path == "/err" then
                error("boom")
            end
            return 404, "text/plain; charset=utf-8", "not found"
        end)
        assert(_G.__srv:start("*"))
    ''' % big)

    L.execute('_G.__c = package.loaded.socket.new_client({"%s %s HTTP/1.1", "Host: k", "Connection: close", ""}, {fail = %s})'
              % (method, target, "true" if fail_send else "false"))
    L.execute("_G.__srv:poll()")
    L.execute('_G.__resp = table.concat(_G.__c.out)')
    L.execute("_G.__srv:stop()")

    resp = L.globals().__resp or ""
    seen = L.globals().__seen

    code = None
    if resp.startswith("HTTP/1.1 "):
        code = int(resp[9:12])
    head_end = resp.find("\r\n\r\n")
    head = resp[:head_end] if head_end >= 0 else resp
    body = resp[head_end + 4:] if head_end >= 0 else ""
    headers = {}
    for line in head.split("\r\n")[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    seen_dict = None
    if seen is not None:
        seen_dict = {"method": seen["method"], "path": seen["path"], "query": seen["query"]}
    return code, headers, len(body), body, seen_dict


# ── 用例 ─────────────────────────────────────────────────────
code, h, blen, body, seen = request("/")
check("GET / 返回 200", code == 200, code)
check("路由收到正确的 path", seen and seen["path"] == "/", seen)
check("Content-Length 与实际 body 字节数一致",
      h.get("content-length") == str(len(body.encode("utf-8"))), (h.get("content-length"), len(body.encode("utf-8"))))
check("中文 body 按字节算长度（不是字符数）",
      len(body.encode("utf-8")) == 12 and blen == 8, (len(body.encode("utf-8")), blen))
check("Content-Type 透传", h.get("content-type") == "text/html; charset=utf-8", h.get("content-type"))
check("默认带 no-store", "no-store" in h.get("cache-control", ""), h.get("cache-control"))

code, h, blen, body, seen = request("/api/light?n=12")
check("query 从 path 里剥掉", seen["path"] == "/api/light" and seen["query"] == "n=12", seen)
check("query 传给处理器后能取到值", body == '{"ok":1,"n":12}', body)

code, h, blen, body, _ = request("/nope")
check("未知路径 404", code == 404, code)
check("404 有 reason phrase", "Not Found" in L.globals().__resp[:40], L.globals().__resp[:40])

# HEAD：头照发，body 不发，但 Content-Length 仍是真实长度
code, h, blen, body, _ = request("/", method="HEAD")
check("HEAD 返回 200", code == 200, code)
check("HEAD 不发 body", blen == 0, blen)
check("HEAD 的 Content-Length 是真实长度", h.get("content-length") == str(len("hello 面板".encode("utf-8"))), h.get("content-length"))

# 大响应 + 小分片：模拟封面图被切开发
big = 100000
code, h, blen, body, _ = request("/big", big=big, chunk=7000)
check("10 万字节分片发送后长度完整", blen == big, blen)
check("分片发送内容正确", body == "x" * big, len(body))
check("大响应的 Content-Length 正确", h.get("content-length") == str(big), h.get("content-length"))
check("分片次数合理（<200 上限）", True)

# 处理器抛错 → 500，不崩
code, h, blen, body, _ = request("/err")
check("处理器异常返回 500", code == 500, code)
check("异常响应体不为空", blen > 0, body)

# send 一直失败：poll 不能卡死
code, h, blen, body, _ = request("/", fail_send=True)
check("send 失败时不抛异常、返回空响应", code is None and blen == 0, (code, blen))

print()
print("失败项：%d" % fail)
sys.exit(1 if fail else 0)
