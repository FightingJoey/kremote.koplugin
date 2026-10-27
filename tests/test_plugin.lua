-- 脱离 KOReader UI 的 main.lua 链路测试：mock 掉 UI 依赖，验证
-- 模块加载、状态采集、路由分派、事件名、真实 HTTP 响应
-- 运行: cd /mnt/us/koreader && ./luajit /tmp/kremote/test_plugin.lua

require("setupkoenv")
local socket = require("socket")

----------------------------------------------------------------------
-- mocks
----------------------------------------------------------------------

local UIManager_events = {}
local ui_events = {}
local scheduled = {}

package.preload["logger"] = function()
    return { dbg = function() end, info = function() end, warn = function() end, err = function() end }
end

package.preload["gettext"] = function()
    return function(s) return s end
end

package.preload["ffi/util"] = function()
    return {
        template = function(str, ...)
            local args = { ... }
            return (str:gsub("%%(%d)", function(i)
                local v = args[tonumber(i)]
                return v == nil and "" or tostring(v)
            end))
        end,
    }
end

package.preload["pluginshare"] = function()
    return { pause_auto_suspend = false }
end

package.preload["ui/event"] = function()
    local E = {}
    E.__index = E
    function E:new(name, arg)
        return setmetatable({ handler = name, args = arg }, E)
    end
    return E
end

package.preload["ui/uimanager"] = function()
    return {
        night_mode = false,
        getElapsedTimeSinceBoot = function() return _G.__elapsed or 1000 end,
        scheduleIn = function(_, delay, fn) scheduled[#scheduled + 1] = fn end,
        unschedule = function() end,
        show = function(_, w) UIManager_events[#UIManager_events + 1] = w end,
        broadcastEvent = function(_, ev)
            UIManager_events[#UIManager_events + 1] = "broadcast:" .. ev.handler
        end,
    }
end

package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, o) return o end }
end

package.preload["device"] = function()
    -- 带 setIntensity 的假 powerd，用来验证 /api/light 真的调到硬件层
    local powerd = {
        fl_max = 24,
        fl_intensity = 3,
        setIntensity = function(self, n)
            _G.__last_intensity = n
            self.fl_intensity = n
        end,
    }
    return {
        getPowerDevice = function()
            return {
                getCapacity = function() return 77 end,
                isCharging = function() return true end,
            }
        end,
        powerd = powerd,
    }
end

package.preload["ui/widget/container/widgetcontainer"] = function()
    local WC = {}
    WC.__index = WC
    function WC:extend(o)
        o = o or {}
        o.__index = o
        function o:new(opts)
            opts = opts or {}
            setmetatable(opts, { __index = self })
            if opts.init then opts:init() end
            return opts
        end
        return setmetatable(o, { __index = WC })
    end
    return WC
end

----------------------------------------------------------------------
-- load plugin
----------------------------------------------------------------------

package.path = "/tmp/kremote/kremote.koplugin/?.lua;" .. package.path

G_reader_settings = {
    isTrue = function(_, k) return k == "night_mode" and true or false end,
    readSetting = function(_, k, d) return d end,
    saveSetting = function() end,
}

local KRemote = dofile("/tmp/kremote/kremote.koplugin/main.lua")
print("LOAD\tOK  name=" .. tostring(KRemote.name))

local fake_ui = {
    document = {
        file = "/mnt/us/documents/测试书.epub",
        getCurrentPage = function() return 12 end,
        getPageCount = function() return 240 end,
        getProps = function() return { title = "长生仙族", authors = "某作者" } end,
    },
    handleEvent = function(_, ev)
        ui_events[#ui_events + 1] = ev.handler .. "(" .. tostring(ev.args) .. ")"
        return true
    end,
    menu = { registerToMainMenu = function() end },
    -- AutoSuspend 插件的实例，用来验证"手机动作算一次用户操作"
    autosuspend = { last_action_time = 0 },
}

local plugin = KRemote:new{ ui = fake_ui }
print("INIT\tui attached=" .. tostring(plugin.ui ~= nil))

----------------------------------------------------------------------
-- status
----------------------------------------------------------------------

print("STATUS\t" .. plugin:statusJSON())

----------------------------------------------------------------------
-- 自动休眠：动作算一次用户操作，纯状态轮询不算
----------------------------------------------------------------------

_G.__elapsed = 5000
plugin:route("GET", "/api/status", "")
print("SLEEP\t轮询后 last_action_time=" .. tostring(fake_ui.autosuspend.last_action_time) .. "  期望 0")
plugin:route("GET", "/api/next", "")
print("SLEEP\t翻页后 last_action_time=" .. tostring(fake_ui.autosuspend.last_action_time) .. "  期望 5000")

----------------------------------------------------------------------
-- routes
----------------------------------------------------------------------

local function hit(path, query)
    local code, ctype, body = plugin:route("GET", path, query or "")
    print(string.format("ROUTE %-14s -> %s  %d bytes", path, tostring(code), #body))
    return body
end

hit("/api/status")
hit("/api/next")
hit("/api/prev")
hit("/api/chapter_next")
hit("/api/font_inc")
hit("/api/night")
hit("/api/refresh")
hit("/api/light", "n=9")
print("LIGHT\tsetIntensity 收到=" .. tostring(_G.__last_intensity))
hit("/api/light", "n=999")
print("LIGHT\t超上限夹取后=" .. tostring(_G.__last_intensity))
hit("/api/bogus")
hit("/")

----------------------------------------------------------------------
-- 书架场景（常驻插件）：没有打开文档时，文档相关动作要明确报错
----------------------------------------------------------------------

plugin:onCloseDocument()
local c1, _, b1 = plugin:route("GET", "/api/next", "")
print("SHELF\t/api/next  -> " .. tostring(c1) .. "  " .. tostring(b1))
local c2 = plugin:route("GET", "/api/night", "")
print("SHELF\t/api/night -> " .. tostring(c2) .. "  (全局动作应放行)")
plugin:onReaderReady()

print("UI_EVENTS\t" .. table.concat(ui_events, ", "))
print("UM_EVENTS\t" .. tostring(#UIManager_events))

----------------------------------------------------------------------
-- real http server through plugin
----------------------------------------------------------------------

local fw_ok, fw_owned = plugin:openFirewall()
print("FIREWALL\tok=" .. tostring(fw_ok) .. " owned_by_us=" .. tostring(fw_owned))

local ok, err = plugin:startServer(true)
print("START\t" .. (ok and "OK" or "false"))

if ok then
    local c = assert(socket.tcp())
    c:settimeout(2)
    c:connect("127.0.0.1", 18080)
    c:send("GET /api/status HTTP/1.1\r\nHost: k\r\nConnection: close\r\n\r\n")
    for _ = 1, 8 do
        plugin:pollOnce()
        socket.sleep(0.02)
    end
    local resp = c:receive("*a") or ""
    c:close()
    local status = resp:match("^HTTP/1%.1 (%d+)")
    local body = resp:match("\r\n\r\n(.*)$") or ""
    print("HTTP\tstatus=" .. tostring(status) .. " body=" .. body)
    plugin:stopServer(true)
    print("STOP\tOK")
else
    print("START\tskipped: 18080 已被真实运行的服务占用，属预期")
end

print("DONE")
