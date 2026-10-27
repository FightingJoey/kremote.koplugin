--[[
httpcore.lua - 极简非阻塞 HTTP/1.1 服务端

只做三件事：接受连接、读请求行 + 请求头、把路由结果写回去。
不依赖 KOReader 的任何模块，只依赖 LuaSocket，因此可以脱离 KOReader
在设备上用 luajit 单独跑通验证。

被驱动方式：调用方周期性调 poll()，每次最多处理 max_per_poll 个连接。
server socket 设为非阻塞，accept 立即返回，不会卡住 UI 事件循环。

关于大响应（封面图）：
LuaSocket 的 send 在超时模式下可能只发出一部分，直接 close 会让浏览器
收到截断的图片。这里用循环把剩余字节发完，并把写超时放宽到 1 秒 ——
封面图最大几十 KB，局域网上远用不到这么久。
]]

local socket = require("socket")

local HttpCore = {}
HttpCore.__index = HttpCore

local REASON = {
    [200] = "OK",
    [204] = "No Content",
    [304] = "Not Modified",
    [400] = "Bad Request",
    [403] = "Forbidden",
    [404] = "Not Found",
    [405] = "Method Not Allowed",
    [409] = "Conflict",
    [500] = "Internal Server Error",
}

-- handler(method, path, query) -> code, content_type, body[, extra_headers]
function HttpCore.new(port, handler, opts)
    opts = opts or {}
    return setmetatable({
        port = port,
        handler = handler,
        max_per_poll = opts.max_per_poll or 8,
        on_error = opts.on_error,
    }, HttpCore)
end

function HttpCore:start(host)
    local server, err = socket.bind(host or "*", self.port)
    if not server then
        return nil, tostring(err)
    end
    server:settimeout(0)
    self.server = server
    return true
end

function HttpCore:stop()
    if self.server then
        pcall(function() self.server:close() end)
        self.server = nil
    end
end

local function parse_request_line(line)
    if type(line) ~= "string" then return nil end
    local method, target = line:match("^(%u+)%s+(%S+)")
    if not method then return nil end
    local path, query = target:match("^([^?]*)%??(.*)$")
    return method, path or target, query or ""
end

-- 把 data 全部写完；返回是否成功
--
-- 注意 LuaSocket 的语义：send(data, i) 里 i 是"起始字节索引"（1 起），
-- 返回值 last 是"最后发出的字节索引"，partial 同样是索引而不是数量。
-- 所以推进游标要用 last，不能拿返回值当已发包数去累加。
local function send_all(client, data)
    if type(data) ~= "string" or data == "" then return true end
    local total = #data
    local sent = 0
    local guard = 0
    while sent < total do
        local last, err, partial = client:send(data, sent + 1)
        if last then
            sent = last
        elseif type(partial) == "number" and partial > sent then
            sent = partial
        else
            return false, err
        end
        guard = guard + 1
        if guard > 200 then return false, "send stalled" end
    end
    return true
end

-- 包一层，避免 respond 里出错把连接状态搞乱
local function send_packet(client, data)
    local ok, err = pcall(send_all, client, data)
    if not ok then return false, err end
    return true
end

function HttpCore:respond(client, code, ctype, body, extra_headers, omit_body)
    body = body or ""
    local head = {
        string.format("HTTP/1.1 %d %s", code, REASON[code] or "OK"),
        "Content-Type: " .. (ctype or "text/plain; charset=utf-8"),
        "Content-Length: " .. tostring(#body),
        "Connection: close",
    }
    if extra_headers then
        for _, h in ipairs(extra_headers) do head[#head + 1] = h end
    else
        head[#head + 1] = "Cache-Control: no-store, no-cache, must-revalidate"
        head[#head + 1] = "Pragma: no-cache"
    end
    local packet = table.concat(head, "\r\n") .. "\r\n\r\n"
    -- 写超时放宽到 1 秒：读请求头用 0.25 秒够，写几十 KB 的图要更宽裕
    pcall(function() client:settimeout(1, "b") end)
    if omit_body then
        send_packet(client, packet)   -- HEAD：头照发，body 不发
    else
        send_packet(client, packet .. body)
    end
end

function HttpCore:serve(client)
    client:settimeout(0.25, "t")
    local line = client:receive("*l")
    if not line then return end
    local method, path, query = parse_request_line(line)
    if not method then return end
    -- 读完请求头，读到空行即止；加行数上限，防止畸形请求卡住
    local n = 0
    while n < 32 do
        local l = client:receive("*l")
        if not l or l == "" then break end
        n = n + 1
    end
    local ok, code, ctype, body, extra = pcall(self.handler, method, path, query)
    if not ok then
        if self.on_error then self.on_error(code) end
        self:respond(client, 500, "text/plain; charset=utf-8", "internal error")
        return
    end
    self:respond(client, code, ctype, body, extra, method == "HEAD")
end

function HttpCore:poll()
    if not self.server then return 0 end
    local count = 0
    for _ = 1, self.max_per_poll do
        local client = self.server:accept()
        if not client then break end
        count = count + 1
        local ok, err = pcall(function() self:serve(client) end)
        pcall(function() client:close() end)
        if not ok and self.on_error then self.on_error(err) end
    end
    return count
end

return HttpCore
