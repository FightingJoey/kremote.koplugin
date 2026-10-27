--[[
httpcore.lua - 极简非阻塞 HTTP/1.1 服务端

只做三件事：接受连接、读请求行 + 请求头、把路由结果写回去。
不依赖 KOReader 的任何模块，只依赖 LuaSocket，因此可以脱离 KOReader
在设备上用 luajit 单独跑通验证。

被驱动方式：调用方周期性调 poll()，每次最多处理 max_per_poll 个连接。
server socket 设为非阻塞，accept 立即返回，不会卡住 UI 事件循环。
]]

local socket = require("socket")

local HttpCore = {}
HttpCore.__index = HttpCore

local REASON = {
    [200] = "OK",
    [204] = "No Content",
    [400] = "Bad Request",
    [404] = "Not Found",
    [500] = "Internal Server Error",
}

-- handler(method, path, query) -> code, content_type, body
function HttpCore.new(port, handler, opts)
    opts = opts or {}
    return setmetatable({
        port = port,
        handler = handler,
        max_per_poll = opts.max_per_poll or 4,
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

function HttpCore:respond(client, code, ctype, body)
    body = body or ""
    local head = string.format(
        "HTTP/1.1 %d %s\r\n" ..
        "Content-Type: %s\r\n" ..
        "Content-Length: %d\r\n" ..
        "Cache-Control: no-store, no-cache, must-revalidate\r\n" ..
        "Pragma: no-cache\r\n" ..
        "Connection: close\r\n\r\n",
        code, REASON[code] or "OK", ctype or "text/plain; charset=utf-8", #body)
    pcall(function() client:send(head .. body) end)
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
    local ok, code, ctype, body = pcall(self.handler, method, path, query)
    if not ok then
        if self.on_error then self.on_error(code) end
        self:respond(client, 500, "text/plain; charset=utf-8", "internal error")
        return
    end
    self:respond(client, code, ctype, body)
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
