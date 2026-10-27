require("setupkoenv")
local socket = require("socket")
local u = socket.udp()
u:settimeout(0.5)
local ok = u:setpeername("8.8.8.8", 80)
print("setpeername\t" .. tostring(ok))
if ok then
    local ip, port = u:getsockname()
    print("IP\t\t" .. tostring(ip) .. ":" .. tostring(port))
end
u:close()
print("DONE")
