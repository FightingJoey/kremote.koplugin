#!/usr/bin/env python3
"""本机模拟测试：不依赖 Kindle，用 lupa 起一个 Lua 运行时，
mock 掉 KOReader 的模块，跑通书库扫描 / 书架 JSON / 封面降级。

运行：python3 tests/mock_shelf.py
依赖：pip install lupa
"""
import os
import shutil
import sys
import time

from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.dirname(HERE)
MOCK = "/tmp/krmock"

# ── 造一个假书库 ─────────────────────────────────────────────
def build_fixture():
    if os.path.isdir(MOCK):
        shutil.rmtree(MOCK)
    docs = os.path.join(MOCK, "documents")
    os.makedirs(os.path.join(docs, "子目录"))
    os.makedirs(os.path.join(docs, ".hidden"))
    os.makedirs(os.path.join(docs, "三体.sdr"))      # sidecar 目录要跳过
    os.makedirs(os.path.join(MOCK, "settings"))

    for rel in [
        "三体.epub",
        "活着.epub",
        "子目录/百年孤独.pdf",
        ".hidden/不该出现.epub",
        "三体.sdr/metadata.lua",
        "封面测试.azw3",
        "说明.md",          # 非书，应被忽略
    ]:
        p = os.path.join(docs, rel)
        with open(p, "wb") as f:
            f.write(b"x" * 32)

    # 让书的 mtime 固定，便于封面缓存判定
    old = time.time() - 86400
    for root, _, files in os.walk(docs):
        for fn in files:
            os.utime(os.path.join(root, fn), (old, old))

    hist = [
        {"time": 1793000000, "file": os.path.join(docs, "三体.epub")},
        {"time": 1792900000, "file": os.path.join(docs, "活着.epub")},
        {"time": 1792800000, "file": os.path.join(docs, "已删除.epub")},   # 不存在，应跳过
        {"time": 1792700000, "file": os.path.join(docs, "子目录/百年孤独.pdf")},
    ]
    with open(os.path.join(MOCK, "history.lua"), "w", encoding="utf-8") as f:
        f.write("return {\n")
        for h in hist:
            f.write('  { time = %d, file = [[%s]] },\n' % (h["time"], h["file"]))
        f.write("}\n")


# ── Python 侧的 lfs 实现 ─────────────────────────────────────
def attributes(path, field=None):
    try:
        st = os.stat(path)
    except OSError:
        return None
    mode = "directory" if os.path.isdir(path) else ("file" if os.path.isfile(path) else "other")
    if field == "mode":
        return mode
    if field == "size":
        return st.st_size
    if field == "modification":
        return int(st.st_mtime)
    return {"mode": mode, "size": st.st_size, "modification": int(st.st_mtime)}


def make_dir_iter(path):
    try:
        entries = [".", ".."] + sorted(os.listdir(path))
    except OSError:
        entries = []
    it = iter(entries)

    def nxt(_state=None, _ctrl=None):
        return next(it, None)

    return nxt


def lfs_dir(path):
    return make_dir_iter(path)


# ── 起 Lua ───────────────────────────────────────────────────
build_fixture()

L = LuaRuntime(unpack_returned_tuples=True)
g = L.globals()
g.LFS_ATTR = attributes
g.LFS_DIR = lfs_dir
g.MOCK_DIR = MOCK
g.PLUGIN_DIR = PLUGIN

L.execute(r'''
package.preload["logger"] = function()
    return { dbg=function() end, info=function() end, warn=function() end, err=function() end }
end

package.preload["gettext"] = function()
    -- KOReader 的 gettext 返回的是可调用 table（__call），所以能挂 .ngettext
    local f = setmetatable({}, { __call = function(_, s) return s end })
    f.ngettext = function(a, b, n) return n == 1 and a or b end
    f.pgettext = function(_, s) return s end
    return f
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
        fileExists = function(p)
            local f = io.open(p, "rb")
            if f then f:close() return true end
            return false
        end,
        makePath = function(p) os.execute("mkdir -p '" .. p .. "'") return true end,
    }
end

-- Kindle 的 lfs：attributes / dir 由 Python 注入
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = LFS_ATTR,
        dir = LFS_DIR,
        mkdir = function() return true end,
    }
end

package.preload["datastorage"] = function()
    return {
        getDataDir = function() return MOCK_DIR end,
        getSettingsDir = function() return MOCK_DIR .. "/settings" end,
    }
end

package.preload["docsettings"] = function()
    local DS = {}
    DS.__index = DS
    DS.open = function(_, path)
        return setmetatable({ path = path }, DS)
    end
    DS.readSetting = function(self, k)
        -- 用文件名里的关键词区分进度，方便断言
        if k == "percent_finished" then
            if self.path:find("三体") then return 0.4234 end
            if self.path:find("活着") then return 1.0 end
            return nil
        end
        return nil
    end
    DS.close = function() end
    return DS
end

package.preload["ui/widget/booklist"] = function()
    return {
        book_info_cache = {},
        getBookInfo = function(file)
            -- 走 DocSettings 那条兜底路径，验证两处都能拿到进度
            return { been_opened = true }
        end,
    }
end

package.preload["bookinfomanager"] = function()
    -- 假 BlitBuffer：只实现被测代码用到的四个方法
    local mkBB
    mkBB = function(w, h, policy)
        local o = {}
        o.getWidth = function() return w end
        o.getHeight = function() return h end
        o.scale = function(_, nw, nh)
            _G.__scale_calls = (_G.__scale_calls or 0) + 1
            _G.__scale_to = nw .. "x" .. nh
            return mkBB(nw, nh, policy)
        end
        o.writeToFile = function(_, path, fmt, _quality)
            _G.__write_calls = (_G.__write_calls or 0) + 1
            _G.__last_fmt = fmt
            if policy == "png_only" and fmt ~= "png" then return false, "mock: jpg 不可用" end
            local f = io.open(path, "wb")
            if not f then return false, "mock: 打不开" end
            if fmt == "png" then
                f:write("\137PNG\r\n\26\n")
            else
                f:write("\255\216\255")           -- JPEG 魔数
            end
            f:write(string.rep("x", 400))
            f:close()
            return true
        end
        return o
    end

    local BIM = {}
    BIM.getBookInfo = function(_, path)
        local base = path:match("([^/]+)$") or path
        if base:find("三体") then
            return { title = "三体", authors = "刘慈欣", has_cover = "Y",
                     cover_bb = mkBB(600, 900, "jpeg") }
        end
        if base:find("活着") then
            return { title = "活着", authors = "余华", has_cover = "Y",
                     cover_bb = mkBB(1000, 1500, "png_only") }
        end
        if base:find("封面测试") then
            return { title = "封面测试", authors = "某人", has_cover = "Y" }
        end
        return { title = base:gsub("%.[^.]+$", ""), authors = "作者甲", has_cover = nil }
    end
    return BIM
end

package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function() end, unschedule = function() end,
        show = function() end, broadcastEvent = function() end,
        getElapsedTimeSinceBoot = function() return 0 end,
        quit = function() end,
    }
end

package.preload["ui/widget/infomessage"] = function() return { new = function(_, o) return o end } end
-- 本机没有 LuaSocket：只让 httpcore 能加载，不真的起服务
package.preload["socket"] = function()
    return {
        bind = function() return nil, "mock: no socket" end,
        udp = function() return nil end,
    }
end
package.preload["ui/event"] = function()
    local E = {}; E.__index = E
    function E:new(n, a) return setmetatable({ handler = n, args = a }, E) end
    return E
end
package.preload["device"] = function()
    return {
        getPowerDevice = function()
            local p = { fl_max = 24, fl_intensity = 5, setIntensity = function(self, n) self.fl_intensity = n end }
            return p
        end,
        powerd = { fl_max = 24, fl_intensity = 5, setIntensity = function() end },
    }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    local WC = {}; WC.__index = WC
    function WC:extend(o)
        o = o or {}; o.__index = o
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
''')

L.execute(r'''
G_reader_settings = {
    isTrue = function(_, k) return k == "night_mode" end,
    readSetting = function(_, k, d) return d end,
    saveSetting = function() end,
}
''')

L.execute(r'''
local Library = assert(loadfile(PLUGIN_DIR .. "/library.lua"))()
_G.Library = Library

local KRemote = assert(loadfile(PLUGIN_DIR .. "/main.lua"))()
_G.KRemote = KRemote
''')

# ── 断言 ─────────────────────────────────────────────────────
fail = 0


def check(name, cond, extra=""):
    global fail
    print(("PASS  " if cond else "FAIL  ") + name + ("   " + str(extra) if extra else ""))
    if not cond:
        fail += 1


shelf = L.eval("Library.shelf(true)")
books = shelf["books"]
recent = shelf["recent"]

titles = [books[i]["title"] for i in range(1, len(books) + 1)]
paths = [books[i]["path"] for i in range(1, len(books) + 1)]

check("扫描到 4 本书（跳过 .hidden 与 .sdr 和 .md）", len(books) == 4, titles)
check("子目录被递归到", any("百年孤独" in p for p in paths))
check("隐藏目录被跳过", not any(".hidden" in p for p in paths))
check("sidecar 目录被跳过", not any(".sdr" in p for p in paths))
check("非书籍后缀被忽略", not any(p.endswith(".md") for p in paths))
check("书目按书名排序", titles == sorted(titles), titles)

recent_titles = [recent[i]["title"] for i in range(1, len(recent) + 1)]
check("最近阅读 3 本（不存在的已跳过）", len(recent) == 3, recent_titles)
check("最近阅读按时间倒序", recent_titles[0] == "三体", recent_titles)

pct = {books[i]["title"]: books[i]["percent"] for i in range(1, len(books) + 1)}
check("进度 三体 = 42.3", abs(pct.get("三体", -1) - 42.3) < 0.01, pct.get("三体"))
check("进度 活着 = 100", abs(pct.get("活着", -1) - 100) < 0.01, pct.get("活着"))
check("未读的进度为 0", pct.get("封面测试") == 0, pct.get("封面测试"))

# 封面：mock 的 BIM 给了 has_cover=Y 但没有 cover_bb，且没有 BookInfo 可降级
cover_test = next(b for b in [books[i] for i in range(1, len(books) + 1)] if "封面测试" in b["title"])
check("has_cover 透传到前端", cover_test["has_cover"] is True)

cov = L.eval('Library.cover("%s")' % cover_test["path"].replace("\\", "\\\\"))
check("没有可用封面的机器上不崩、返回 nil", cov is None)

# hash 反查
h = books[1]["hash"]
back = L.eval('Library.findByHash("%s")' % h)
check("hash 能反查到路径", back == paths[0], back)

bad = L.eval('Library.findByHash("deadbeef")')
check("未知 hash 返回 nil", bad is None)

# 书架 JSON
json = L.eval("KRemote.shelfJSON(KRemote, true)")
import json as jsonlib
try:
    data = jsonlib.loads(json)
    ok_json = True
except Exception as e:
    ok_json = False
    data = {}
    print("       JSON 解析失败:", e)

check("shelfJSON 是合法 JSON", ok_json)
check("JSON ok=1", data.get("ok") == 1)
check("JSON 带 view 字段", data.get("view") in ("shelf", "reader"), data.get("view"))
check("JSON recent 3 条", len(data.get("recent", [])) == 3)
check("JSON books 4 条", len(data.get("books", [])) == 4)
if data.get("books"):
    b0 = data["books"][0]
    check("书籍字段齐全 h/t/a/p/c", all(k in b0 for k in ("h", "t", "a", "p", "c")), b0)
    check("hash 是 8 位十六进制", len(b0["h"]) == 8 and all(c in "0123456789abcdef" for c in b0["h"]), b0["h"])

# ── 封面生成链路 ─────────────────────────────────────────────
santi = next(b for b in [books[i] for i in range(1, len(books) + 1)] if b["title"] == "三体")
huozhe = next(b for b in [books[i] for i in range(1, len(books) + 1)] if b["title"] == "活着")

L.execute("_G.__scale_calls, _G.__write_calls, _G.__scale_to = 0, 0, nil")
L.execute('_G.__cov, _G.__ctype = Library.cover(%s)' % ('[[' + santi["path"] + ']]'))
# lupa 默认把 Lua 字符串按 utf-8 解码，二进制图过不了边界，
# 所以长度和相等性都在 Lua 侧算好再取数字/布尔
L.execute("_G.__cov_len = _G.__cov and #_G.__cov or 0")
L.execute("_G.__cov_is_jpeg = _G.__cov ~= nil and string.byte(_G.__cov, 1) == 0xFF"
          " and string.byte(_G.__cov, 2) == 0xD8")

cov_len = L.globals().__cov_len
ctype = L.globals().__ctype
scale_to = L.globals().__scale_to

check("封面生成成功", cov_len > 0, "%d bytes" % cov_len)
check("封面是 JPEG", ctype == "image/jpeg", ctype)
check("返回体确实是 JPEG 魔数", L.globals().__cov_is_jpeg is True)
check("缩放到宽 260、等比高 390", scale_to == "260x390", scale_to)
check("首选 JPEG 编码", L.globals().__last_fmt == "jpg", L.globals().__last_fmt)

cache_dir = os.path.join(MOCK, "settings", "kremote_covers")
jpg = os.path.join(cache_dir, santi["hash"] + ".jpg")
check("封面落盘缓存", os.path.isfile(jpg), jpg)
check("落盘文件非空", os.path.getsize(jpg) > 100 if os.path.isfile(jpg) else False,
      os.path.getsize(jpg) if os.path.isfile(jpg) else 0)

# 第二次请求应该命中缓存，不再解码编码
L.execute("_G.__write_calls = 0")
L.execute('_G.__cov2 = Library.cover(%s)' % ('[[' + santi["path"] + ']]'))
L.execute("_G.__same = (_G.__cov2 == _G.__cov)")
check("二次请求命中缓存、不再编码", L.globals().__write_calls == 0,
      "write_calls=%s" % L.globals().__write_calls)
check("缓存内容一致", L.globals().__same is True)

# JPEG 编码失败的机器要走 PNG 兜底
L.execute("_G.__scale_calls, _G.__write_calls = 0, 0")
L.execute('_G.__cov3, _G.__ctype3 = Library.cover(%s)' % ('[[' + huozhe["path"] + ']]'))
check("JPEG 失败时回退 PNG", L.globals().__ctype3 == "image/png", L.globals().__ctype3)
png = os.path.join(cache_dir, huozhe["hash"] + ".png")
check("PNG 也落了盘", os.path.isfile(png), png)
check("不会同时留一份 jpg", not os.path.isfile(os.path.join(cache_dir, huozhe["hash"] + ".jpg")))

print()
print("失败项：%d" % fail)
sys.exit(1 if fail else 0)