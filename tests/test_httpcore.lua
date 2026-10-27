-- 脱离 KOReader 的自测：单进程起服务 + 自发请求
-- 运行: cd /mnt/us/koreader && ./luajit /tmp/kremote/test_httpcore.lua

require("setupkoenv")
local socket = require("socket")
local HttpCore = dofile("/tmp/kremote/kremote.koplugin/httpcore.lua")

local PORT = 18999
local hits = {}

local srv = HttpCore.new(PORT, function(method, path, query)
    hits[#hits + 1] = string.format("%s %s ?%s", method, path, tostring(query))
    if path == "/" then
        return 200, "text/html; charset=utf-8", "<h1>panel ok</h1>"
    elseif path == "/api/status" then
        return 200, "application/json; charset=utf-8",
            '{"ok":1,"title":"测试书","page":42,"pages":300,"percent":14.0}'
    elseif path == "/api/next" then
        return 200, "application/json; charset=utf-8", '{"ok":1,"page":43}'
    end
    return 404, "text/plain; charset=utf-8", "not found"
end)

local ok, err = srv:start("*")
print("BIND\t", ok and "OK" or tostring(err))
if not ok then os.exit(1) end

local function request(target)
    local c = assert(socket.tcp())
    c:settimeout(2)
    local okc = c:connect("127.0.0.1", PORT)
    if not okc then print("CONNECT FAIL", target); return nil end
    c:send("GET " .. target .. " HTTP/1.1\r\nHost: kindle\r\nConnection: close\r\n\r\n")
    -- 服务器侧非阻塞处理一次（可能要多轮，因为 accept 队列 + 读头）
    for _ = 1, 6 do
        srv:poll()
        socket.sleep(0.02)
    end
    local resp = c:receive("*a")
    c:close()
    return resp
end

local paths = { "/", "/api/status", "/api/next", "/nope" }
for _, p in ipairs(paths) do
    local r = request(p)
    if r then
        local status = r:match("^HTTP/1%.1 (%d+)")
        local clen = r:match("Content%-Length: (%d+)")
        local ctype = r:match("Content%-Type: ([^\r\n]+)")
        local body = r:match("\r\n\r\n(.*)$") or ""
        print(string.format("REQ %-14s -> %s  len=%s/%d  type=%s",
            p, tostring(status), tostring(clen), #body, tostring(ctype)))
    else
        print("REQ " .. p .. " -> NO RESPONSE")
    end
end

-- 连发两个，验证连续处理不粘包
request("/api/next")
request("/api/next")

srv:stop()
print("HITS\t" .. #hits)
for _, h in ipairs(hits) do print("  " .. h) end
print("DONE")
