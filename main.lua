--[[
kremote.koplugin - 手机浏览器遥控 KOReader

在 Kindle 上起一个极简 HTTP 服务，手机浏览器打开先看到书库（最近阅读轮播 +
两行全部书籍），点一本书 Kindle 就跳到那本书；进控制页后能翻页、切章节、
调字号、切夜间模式、调前光，并看到当前页码和电量。
走局域网，不碰蓝牙、不碰内核、不需要 root。

实现要点：
  * HTTP 层在 httpcore.lua，非阻塞 accept，由 UIManager:scheduleIn 驱动，
    不阻塞 KOReader 的事件循环
  * 书库与封面在 library.lua：扫目录 + 读 history.lua + 查 CoverBrowser 的
    SQLite 缓存，封面缩到 260px 宽转 JPEG 落盘，不做现场抽图
  * 翻页用 GotoViewRel 事件（ReaderRolling / ReaderPaging 都实现了），
    对 EPUB 和 PDF 都有效
  * 不干预自动休眠：Kindle 按自己的 30 分钟超时休眠。手机发来的翻页等
    动作会算作一次"用户操作"，重置 AutoSuspend 的计时（否则正用手机翻页，
    设备却会中途睡过去）；纯状态轮询不算，所以放下手机 30 分钟照样休眠
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Event = require("ui/event")
local Device = require("device")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

-- 按本文件所在目录定位附属文件（httpcore.lua / library.lua / panel.html），
-- 不依赖 package.path 是否含插件目录和当前工作目录。
-- 用 require("httpcore") 在部分启动路径下会找不到模块，这里更稳。
local PLUGIN_DIR = (function()
    local src = debug.getinfo(1, "S").source or ""
    return src:match("^@(.*)/[^/]+$") or "."
end)()

local HttpCore = (function()
    local chunk, err = loadfile(PLUGIN_DIR .. "/httpcore.lua")
    if not chunk then
        logger.err("kremote: cannot load httpcore.lua:", tostring(err))
        return nil
    end
    return chunk()
end)()

-- 书库扫描与封面导出。缺这个文件只是书架页用不了，控制页照旧。
local Library = (function()
    local chunk, err = loadfile(PLUGIN_DIR .. "/library.lua")
    if not chunk then
        logger.err("kremote: cannot load library.lua:", tostring(err))
        return nil
    end
    local ok, mod = pcall(chunk)
    if not ok or type(mod) ~= "table" then
        logger.err("kremote: library.lua failed:", tostring(mod))
        return nil
    end
    return mod
end)()

local PORT = 18080
local POLL_INTERVAL = 0.15

----------------------------------------------------------------------
-- 工具
----------------------------------------------------------------------

local function json_escape(v)
    local s = tostring(v == nil and "" or v)
    s = (s:gsub("\\", "\\\\"))
    s = (s:gsub('"', '\\"'))
    s = (s:gsub("[%z\1-\31]", " "))
    return s
end

local function basename(p)
    if type(p) ~= "string" then return "" end
    local name = p:match("([^/]+)$") or p
    return (name:gsub("%.[^./]+$", ""))
end

----------------------------------------------------------------------
-- 手机端面板
----------------------------------------------------------------------

-- 前端页面从 panel.html 读，不内联在 Lua 字符串里：
-- 语法高亮、独立预览、改样式不用碰 Lua
-- 首次请求时读一次并缓存（一次一屏，几百 KB 顶天）
local panel_cache = nil
local function getPanel()
    if panel_cache then return panel_cache end
    local f = io.open(PLUGIN_DIR .. "/panel.html", "rb")
    if not f then
        logger.err("kremote: cannot open panel.html")
        return "<!DOCTYPE html><meta charset=utf-8>"
            .. "<h1>面板文件缺失</h1><p>请重新安装插件。</p>"
    end
    panel_cache = f:read("*a")
    f:close()
    return panel_cache
end

----------------------------------------------------------------------
-- 前光
--
-- 档位由 frontend/device/kindle/powerd.lua 管理，范围 fl_min..fl_max
-- （本机实测 0..24，对应 /sys/class/backlight/bl 的 0..2399，非线性映射）。
-- 走 KOReader 自己的 API，才能和内置亮度控制、觅阅工具栏的状态保持一致；
-- 直接写 sysfs 会让 KOReader 记录的档位与实际脱节，下次恢复亮度时被覆盖。
--
-- 注意定义顺序：这里必须排在 ACTIONS 表之前。Lua 的 local 作用域从声明行
-- 才开始，若把 setLight 放到 ACTIONS 之后，表里引用到的就是全局 nil。
----------------------------------------------------------------------

local function getPowerd()
    local ok, p = pcall(function() return Device:getPowerDevice() end)
    if ok and p and type(p.setIntensity) == "function" then return p end
    if Device and Device.powerd then return Device.powerd end
    return nil
end

-- 返回当前档位、最大档位；设备无前光时返回 nil
local function getLight()
    local p = getPowerd()
    if not p or type(p.fl_max) ~= "number" or p.fl_max <= 0 then return nil, nil end
    local cur = p.fl_intensity
    if type(cur) ~= "number" and type(p.frontlightIntensityHW) == "function" then
        local ok, v = pcall(p.frontlightIntensityHW, p)
        if ok and type(v) == "number" then cur = v end
    end
    if type(cur) ~= "number" then cur = 0 end
    return cur, p.fl_max
end

local function setLight(n)
    local p = getPowerd()
    if not p or type(p.setIntensity) ~= "function" then return false end
    local max = p.fl_max or 24
    n = tonumber(n) or 0
    if n < 0 then n = 0 end
    if n > max then n = max end
    n = math.floor(n + 0.5)
    local ok = pcall(p.setIntensity, p, n)
    return ok
end

----------------------------------------------------------------------
-- 服务状态
--
-- 常驻插件（非 is_doc_only）会在「书架」和「阅读界面」各加载一份实例，
-- 两份实例不能各自 bind 同一个端口，所以底层服务只存一份在模块级表里。
-- 哪份 UI 当前打开了书，就由哪份接收翻页之类的文档相关动作。
----------------------------------------------------------------------

local SERVER = {
    http = nil,
    loop_task = nil,
    fw_owned = false,
    fm_ui = nil,      -- 书架界面（FileManager）
    reader_ui = nil,  -- 阅读界面（ReaderUI）
}

-- 当前打开了文档的阅读界面；在书架或其它界面时返回 nil
local function activeReader()
    local ui = SERVER.reader_ui
    if ui and ui.document then return ui end
    return nil
end

-- 把手机发来的动作记为一次"用户操作"。
-- 只重置 AutoSuspend 的计时，不动 pause_auto_suspend：不操作照样会睡，
-- 但正在用手机翻页时不会因为"手指没碰屏幕"而中途休眠。
-- 纯 /api/status 轮询不走这里，否则面板开着就永远不休眠了。
local function touchActivity()
    local ui = activeReader() or SERVER.fm_ui
    local as = ui and (ui.autosuspend or ui.AutoSuspend)
    if not as or as.last_action_time == nil then return false end
    return pcall(function()
        as.last_action_time = UIManager:getElapsedTimeSinceBoot()
    end)
end

local function readerEvent(name, arg)
    local ui = activeReader()
    if not ui then return end
    ui:handleEvent(Event:new(name, arg))
end

----------------------------------------------------------------------
-- 动作表：名字 -> 具体操作
----------------------------------------------------------------------

local ACTIONS = {
    next = function() readerEvent("GotoViewRel", 1) end,
    prev = function() readerEvent("GotoViewRel", -1) end,
    chapter_next = function() readerEvent("GotoNextChapter") end,
    chapter_prev = function() readerEvent("GotoPrevChapter") end,
    -- ReaderFont:gesToFontSize 对非 table 参数直接返回原值（Dispatcher 传的就是数字），
    -- 传 1 表示步进一级；传 nil 会让它返回 nil 并把 nil 喂给 onChangeSize
    font_inc = function() readerEvent("IncreaseFontSize", 1) end,
    font_dec = function() readerEvent("DecreaseFontSize", 1) end,
    -- 夜间模式和全刷是全局状态，不需要打开文档也能用
    night = function() UIManager:broadcastEvent(Event:new("ToggleNightMode")) end,
    refresh = function() UIManager:broadcastEvent(Event:new("FullRefresh")) end,
    -- /api/light?n=12 —— 需要带参数，签名比其它动作多一个 query
    light = function(self, query)
        -- httpcore 已把 query 从 path 里剥离，"n=12" 是纯查询串，不带问号
        local n = query and tonumber(query:match("n=(%-?%d+)"))
        if n then setLight(n) end
    end,
    -- 重启/退出都必须等 HTTP 响应发出去再动手：handler 返回后 httpcore 才 send，
    -- 在这里同步执行会让手机收到连接重置，看不到任何结果
    restart = function()
        UIManager:scheduleIn(0.6, function()
            -- Kindle 的 koreader.sh 末尾是 exit ${RETURN_VALUE}，没有对退出码 85
            -- 的重启循环，所以 UIManager:restartKOReader()（实质是 quit(85)）
            -- 在这台机器上只会退出、不会重启。改成交给后台 shell 重新拉起。
            os.execute("nohup sh -c 'sleep 4; /var/local/kmc/bin/kpm launch koreader --asap' "
                .. ">/dev/null 2>&1 &")
            UIManager:quit()
        end)
    end,
    quit = function()
        UIManager:scheduleIn(0.6, function()
            -- 先关文档触发保存：quit() 会直接清空窗口栈，不走 onCloseWidget 那条路径
            local ui = activeReader()
            if ui then pcall(function() ui:onClose() end) end
            UIManager:scheduleIn(0.6, function() UIManager:quit() end)
        end)
    end,
}

-- 这些动作必须有打开的文档才有意义，在书架界面上要明确报错而不是静默无效
local DOC_ACTIONS = {
    next = true, prev = true,
    chapter_next = true, chapter_prev = true,
    font_inc = true, font_dec = true,
}

----------------------------------------------------------------------
-- 插件
----------------------------------------------------------------------

local KRemote = WidgetContainer:extend{
    name = "kremote",
    -- 常驻插件：书架和阅读界面都会加载，服务才能在关书、重启之后自己回来。
    -- 若设 is_doc_only = true，插件只在打开文档后才加载，退回书架服务就停了。
}

local function autoStart()
    local ok, v = pcall(function() return G_reader_settings:isTrue("kremote_auto") end)
    return ok and v
end

function KRemote:init()
    -- 书架实例和阅读实例都会走这里，按有没有 document 分别登记
    if self.ui and self.ui.document then
        SERVER.reader_ui = self.ui
    else
        SERVER.fm_ui = self.ui
    end
    self.ui.menu:registerToMainMenu(self)
    if autoStart() then
        -- init 阶段 UIManager 还没开始处理事件，延一会儿再起服务
        UIManager:scheduleIn(2, function()
            if not SERVER.http then self:startServer(true) end
        end)
    end
end

function KRemote:onReaderReady()
    SERVER.reader_ui = self.ui
    if autoStart() and not SERVER.http then
        self:startServer(true)
    end
end

function KRemote:onCloseDocument()
    -- 只注销登记，服务本身继续跑：退回书架后手机那头的页面不该断
    if SERVER.reader_ui == self.ui then SERVER.reader_ui = nil end
end

function KRemote:onCloseWidget()
    if SERVER.reader_ui == self.ui then SERVER.reader_ui = nil end
    if SERVER.fm_ui == self.ui then SERVER.fm_ui = nil end
    -- 两份界面都注销了说明 KOReader 正在退出，这时才真正停服务
    if not SERVER.reader_ui and not SERVER.fm_ui then
        self:stopServer(true)
    end
end

function KRemote:onResume()
    if not SERVER.http then return end
    -- Kindle 休眠时 Wi-Fi 会断开，唤醒重连后 iptables 可能被系统重刷，
    -- 导致端口又不通了；这里幂等地补一次（已有规则时不会重复加）
    local fw_ok, fw_owned = self:openFirewall()
    SERVER.fw_owned = SERVER.fw_owned or fw_owned
    if not fw_ok then
        logger.warn("kremote: failed to reopen firewall after resume")
    end
end

----------------------------------------------------------------------
-- 状态采集
----------------------------------------------------------------------

function KRemote:getStatus()
    local st = {
        ok = 1, title = "", authors = "",
        page = 0, pages = 0, percent = 0,
        battery = -1, charging = 0, night = 0,
        -- 手机端据此决定显示书架页还是控制页
        view = activeReader() and "reader" or "shelf",
    }
    local ui = activeReader()
    local doc = ui and ui.document
    if doc then
        local ok1, cur = pcall(doc.getCurrentPage, doc)
        if ok1 and type(cur) == "number" then st.page = cur end
        local ok2, total = pcall(doc.getPageCount, doc)
        if ok2 and type(total) == "number" then st.pages = total end
        if st.pages > 0 and st.page > 0 then
            st.percent = math.floor(st.page / st.pages * 1000 + 0.5) / 10
        end
        local ok3, props = pcall(doc.getProps, doc)
        if ok3 and type(props) == "table" then
            st.title = props.title or ""
            st.authors = props.authors or ""
            if type(st.authors) == "table" then
                st.authors = table.concat(st.authors, ", ")
            end
        end
        if st.title == "" then st.title = basename(doc.file) end
    end
    local okp, power = pcall(function() return Device:getPowerDevice() end)
    if okp and power then
        local okc, cap = pcall(power.getCapacity, power)
        if okc and type(cap) == "number" then st.battery = cap end
        local okch, ch = pcall(power.isCharging, power)
        if okch then st.charging = ch and 1 or 0 end
    end
    -- 夜间模式没有 UIManager.night_mode 这个字段（ToggleNightMode 只改刷新计数），
    -- 权威状态在 G_reader_settings 的 night_mode，DeviceListener 也读它
    local okn, nm = pcall(function() return G_reader_settings:isTrue("night_mode") end)
    st.night = (okn and nm) and 1 or 0
    local light, lightmax = getLight()
    st.light = light or 0
    st.lightmax = lightmax or 0
    return st
end

function KRemote:statusJSON()
    local s = self:getStatus()
    return string.format(
        '{"ok":1,"view":"%s","title":"%s","authors":"%s","page":%d,"pages":%d,'
        .. '"percent":%.1f,"battery":%d,"charging":%d,"night":%d,'
        .. '"light":%d,"lightmax":%d}',
        s.view, json_escape(s.title), json_escape(s.authors),
        s.page, s.pages, s.percent, s.battery, s.charging, s.night,
        s.light, s.lightmax)
end

----------------------------------------------------------------------
-- 书架
----------------------------------------------------------------------

local function bookJSON(b)
    return string.format(
        '{"h":"%s","t":"%s","a":"%s","p":%.1f,"c":%d}',
        b.hash, json_escape(b.title), json_escape(b.authors),
        b.percent or 0, b.has_cover and 1 or 0)
end

function KRemote:shelfJSON(force)
    if not Library then
        return '{"ok":0,"error":"缺少 library.lua，书架不可用"}'
    end
    local s = self:getStatus()
    local data = Library.shelf(force)
    local out = {
        '{"ok":1,"view":"', s.view, '","battery":', tostring(s.battery),
        ',"charging":', tostring(s.charging), ',"recent":[',
    }
    for i, b in ipairs(data.recent) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = bookJSON(b)
    end
    out[#out + 1] = '],"books":['
    for i, b in ipairs(data.books) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = bookJSON(b)
    end
    out[#out + 1] = "]}"
    return table.concat(out)
end

-- 从 Kindle 当前界面打开一本书
--
-- 真正打开文档会阻塞一两秒（解析文件、建立排版），不能直接在有 HTTP
-- 连接时同步做：那样手机端会等到超时。所以这里只做存在性检查，然后
-- 排一个延时任务，等响应发完之后再切书。
local function scheduleOpenBook(path)
    if type(path) ~= "string" or path == "" then return false, "路径为空" end
    local okf, exists = pcall(function()
        return require("ffi/util").fileExists(path)
    end)
    if okf and not exists then return false, "文件不存在" end

    UIManager:scheduleIn(0.35, function()
        local ui = activeReader()
        local ok, err
        if ui then
            -- 已经在看书：就地切换文档，不新建 ReaderUI 实例
            ok, err = pcall(ui.switchDocument, ui, path)
        else
            -- 在书架界面：走文件管理器正常的打开流程
            ok, err = pcall(function()
                local FileManager = require("apps/filemanager/filemanager")
                local fm = FileManager.instance
                if fm and type(fm.openFile) == "function" then
                    fm:openFile(path)
                    return
                end
                require("apps/reader/readerui"):showDocument(path)
            end)
        end
        if not ok then
            logger.warn("kremote: open book failed", tostring(err))
        end
    end)
    return true
end

-- 关掉当前文档，退回书架（FileManager 一直在窗口栈下面，关掉就露出来）
local function scheduleCloseToShelf()
    if not activeReader() then return true end
    UIManager:scheduleIn(0.35, function()
        local ui = activeReader()
        if not ui then return end
        -- onCloseDocument 只注销 reader_ui 登记，不会停 HTTP 服务
        local ok, err = pcall(ui.onClose, ui, true)
        if not ok then logger.warn("kremote: onClose failed", tostring(err)) end
    end)
    return true
end

----------------------------------------------------------------------
-- 路由
----------------------------------------------------------------------

function KRemote:route(method, path, query)
    if method ~= "GET" and method ~= "HEAD" then
        return 400, "text/plain; charset=utf-8", "only GET"
    end
    if path == "/" or path == "/index.html" then
        return 200, "text/html; charset=utf-8", getPanel()
    end
    if path == "/favicon.ico" then
        return 204, "text/plain", ""
    end
    if path == "/api/status" then
        return 200, "application/json; charset=utf-8", self:statusJSON()
    end

    -- 轻量状态：书架页轮询用，不带书名页码这些
    if path == "/api/state" then
        local s = self:getStatus()
        return 200, "application/json; charset=utf-8", string.format(
            '{"ok":1,"view":"%s","battery":%d,"charging":%d}',
            s.view, s.battery, s.charging)
    end

    if path == "/api/shelf" then
        local force = type(query) == "string" and query:find("r=1") ~= nil
        local ok, json = pcall(self.shelfJSON, self, force)
        if not ok then
            logger.warn("kremote: shelf failed", tostring(json))
            return 500, "application/json; charset=utf-8",
                '{"ok":0,"error":"' .. json_escape(tostring(json)) .. '"}'
        end
        return 200, "application/json; charset=utf-8", json
    end

    if path == "/api/cover" then
        local hash = query and query:match("h=([%w]+)")
        local book = hash and Library and Library.findByHash(hash)
        if not book then return 404, "text/plain; charset=utf-8", "no cover" end
        local ok, data, ctype = pcall(Library.cover, book)
        if not ok or not data then
            return 404, "text/plain; charset=utf-8", "no cover"
        end
        -- 书籍路径以 hash 标识，封面内容只在书文件变动时才会变，可以放心缓存
        return 200, ctype or "image/jpeg", data,
            { "Cache-Control: max-age=86400", "X-Content-Type-Options: nosniff" }
    end

    if path == "/api/open" then
        local hash = query and query:match("h=([%w]+)")
        local book = hash and Library and Library.findByHash(hash)
        if not book then
            return 404, "application/json; charset=utf-8",
                '{"ok":0,"error":"找不到这本书，请刷新书架"}'
        end
        -- 打开文档会阻塞一两秒，先让 HTTP 响应发出去再动手，
        -- 否则手机端会看到连接被重置
        local ok, opened, err = pcall(scheduleOpenBook, book)
        if not ok or not opened then
            return 500, "application/json; charset=utf-8",
                '{"ok":0,"error":"' .. json_escape(tostring(err or opened)) .. '"}'
        end
        touchActivity()
        return 200, "application/json; charset=utf-8", '{"ok":1,"opening":1}'
    end

    if path == "/api/home" then
        local ok, done = pcall(scheduleCloseToShelf)
        if not ok or not done then
            return 500, "application/json; charset=utf-8",
                '{"ok":0,"error":"返回书架失败"}'
        end
        touchActivity()
        return 200, "application/json; charset=utf-8", '{"ok":1,"view":"shelf"}'
    end

    local action = path:match("^/api/([%w_]+)$")
    if action and ACTIONS[action] then
        if DOC_ACTIONS[action] and not activeReader() then
            return 409, "application/json; charset=utf-8",
                '{"ok":0,"error":"Kindle 当前没有打开的书"}'
        end
        local ok, err = pcall(ACTIONS[action], self, query)
        if not ok then
            logger.warn("kremote: action failed", action, tostring(err))
            return 500, "application/json; charset=utf-8",
                '{"ok":0,"error":"' .. json_escape(tostring(err)) .. '"}'
        end
        -- 真有动作才算"用户还在操作"，纯状态轮询不算，避免面板开着永不休眠
        touchActivity()
        return 200, "application/json; charset=utf-8", self:statusJSON()
    end
    return 404, "text/plain; charset=utf-8", "not found"
end

----------------------------------------------------------------------
-- 轮询驱动
----------------------------------------------------------------------

function KRemote:pollOnce()
    local http = SERVER.http
    if not http then return end
    local ok, err = pcall(function()
        -- 每轮最多 poll 4 个连接，避免突发连接把 UI 卡住
        for _ = 1, 4 do
            if http:poll() == 0 then break end
        end
    end)
    if not ok then logger.warn("kremote: poll error", tostring(err)) end
end

function KRemote:scheduleLoop()
    if not SERVER.http then return end
    UIManager:scheduleIn(POLL_INTERVAL, SERVER.loop_task)
end

function KRemote:getIP()
    local socket = require("socket")
    local ok, ip = pcall(function()
        local s = socket.udp()
        if not s then return nil end
        s:settimeout(0.3)
        local set = s:setpeername("8.8.8.8", 80)
        local addr = set and s:getsockname()
        s:close()
        return addr
    end)
    if ok and type(ip) == "string" and ip ~= "0.0.0.0" then return ip end
    return nil
end

----------------------------------------------------------------------
-- 防火墙
--
-- Kindle 固件的 INPUT 链默认策略是 DROP，只显式放行了 SSH 用的 2222
-- （那条规则是 KOReader 的 SSH 插件加的）。不额外开洞的话，socket 虽然
-- 在 0.0.0.0 上 LISTEN，但外部新连接会在内核层面被直接丢掉，
-- 表现为手机和电脑都"连不上"，而设备本机 127.0.0.1 一切正常。
----------------------------------------------------------------------

local FIREWALL_RULE = "-i wlan0 -p tcp --dport " .. PORT ..
    " -m conntrack --ctstate NEW -j ACCEPT"

local function sh(cmd)
    local r = os.execute(cmd)
    return r == 0 or r == true
end

function KRemote:openFirewall()
    -- 已经有就不重复加，也不记为"我们加的"，避免误删别人的规则
    if sh("iptables -C INPUT " .. FIREWALL_RULE .. " 2>/dev/null") then
        return true, false
    end
    if sh("iptables -I INPUT 1 " .. FIREWALL_RULE .. " 2>/dev/null") then
        return true, true
    end
    return false, false
end

function KRemote:closeFirewall()
    if SERVER.fw_owned then
        sh("iptables -D INPUT " .. FIREWALL_RULE .. " 2>/dev/null")
        SERVER.fw_owned = false
    end
end

----------------------------------------------------------------------
-- 启停
----------------------------------------------------------------------

function KRemote:startServer(silent)
    if SERVER.http then
        -- 已经在跑（可能是另一份界面实例起的）：重新确认端口放行
        -- （Kindle 网络重连可能重刷 iptables），顺便再报一次当前地址
        local fw_ok, fw_owned = self:openFirewall()
        SERVER.fw_owned = SERVER.fw_owned or fw_owned
        if not silent then self:showAddress(fw_ok) end
        return true
    end

    if not HttpCore then
        if not silent then
            UIManager:show(InfoMessage:new{
                text = _("遥控插件缺少 httpcore.lua，请重新安装。"),
                timeout = 5,
            })
        end
        return false
    end

    local http = HttpCore.new(PORT, function(method, path, query)
        return self:route(method, path, query)
    end, {
        on_error = function(e) logger.warn("kremote: http error", tostring(e)) end,
    })
    local ok, bind_err = http:start("*")
    if not ok then
        if not silent then
            UIManager:show(InfoMessage:new{
                text = T(_("遥控服务启动失败：%1\n端口 %2 可能被占用。"),
                    tostring(bind_err), PORT),
                timeout = 5,
            })
        end
        return false
    end

    SERVER.http = http
    SERVER.loop_task = function() self:pollOnce(); self:scheduleLoop() end
    self:scheduleLoop()

    local fw_ok, fw_owned = self:openFirewall()
    SERVER.fw_owned = fw_owned
    if not fw_ok then
        logger.warn("kremote: failed to open firewall for port", PORT)
    end

    if not silent then
        self:showAddress(fw_ok)
    else
        logger.info("kremote: auto started on port", PORT)
    end
    return true
end

function KRemote:showAddress(fw_ok)
    local ip = self:getIP()
    local lines = {}
    if ip then
        lines[#lines + 1] = T(_("在手机浏览器打开：\nhttp://%1:%2"), ip, PORT)
    else
        lines[#lines + 1] = T(_("没拿到 IP，请确认 Kindle 已连上 Wi-Fi。\n端口：%1"), PORT)
    end
    if fw_ok == false then
        lines[#lines + 1] = _("端口没能自动放行，手机可能连不上。")
    end
    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n\n"),
        timeout = 7,
    })
end

function KRemote:stopServer(silent)
    if not SERVER.http then return true end
    if SERVER.loop_task then
        pcall(function() UIManager:unschedule(SERVER.loop_task) end)
        SERVER.loop_task = nil
    end
    pcall(function() SERVER.http:stop() end)
    SERVER.http = nil
    self:closeFirewall()
    if not silent then
        UIManager:show(InfoMessage:new{ text = _("手机遥控已停止"), timeout = 3 })
    end
    return true
end

----------------------------------------------------------------------
-- 菜单
----------------------------------------------------------------------

function KRemote:addToMainMenu(menu_items)
    menu_items.kremote = {
        text = _("手机遥控"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("启动遥控服务"),
                callback = function() self:startServer(false) end,
            },
            {
                text = _("停止遥控服务"),
                callback = function() self:stopServer(false) end,
            },
            {
                text = _("显示访问地址"),
                callback = function()
                    local ip = self:getIP()
                    local state = SERVER.http and _("运行中") or _("未启动")
                    local url = ip and ("http://" .. ip .. ":" .. PORT) or _("（无 IP，请检查 Wi-Fi）")
                    UIManager:show(InfoMessage:new{
                        text = T(_("状态：%1\n\n手机浏览器打开：\n%2\n\n端口：%3"), state, url, PORT),
                    })
                end,
            },
            {
                text = _("打开 KOReader 时自动启动"),
                checked_func = function()
                    return G_reader_settings:isTrue("kremote_auto")
                end,
                callback = function()
                    G_reader_settings:saveSetting("kremote_auto",
                        not G_reader_settings:isTrue("kremote_auto"))
                end,
            },
        },
    }
end

return KRemote
