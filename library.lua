--[[
library.lua - 书库扫描、书目元数据、封面导出

给手机端书架页供数据。三件事：
  1. 从 history.lua 读"最近阅读"
  2. 递归扫书库目录，列出全部书籍
  3. 从 CoverBrowser 的 SQLite 缓存里取封面，转成 JPEG 落磁盘

封面为什么不自己抽：
  自己 openDocument() 抽封面，一本书要几百毫秒到几秒，Kindle 的 CPU
  扛不住几十本一起抽。KOReader 自带的 CoverBrowser 插件早就把封面
  解压好、缩略好、zstd 压缩存进 bookinfo_cache.sqlite3 了（文件管理器
  的封面网格就靠它）。直接查库拿 BlitBuffer，只做一次缩放 + 编码。

降级链：
  DB 有封面  -> 直接用（快，纯解压 + 编码）
  DB 有记录但没封面 -> 返回 nil，前端显示占位
  DB 无记录 -> 用 BookInfo 现场抽一次（慢，但结果按文件 mtime 落盘缓存，
              同一本书只会慢这一次）
]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Library = {}

----------------------------------------------------------------------
-- 可识别的书籍扩展名
--
-- 只按扩展名初筛，避免对目录里每个文件都调 DocumentRegistry:hasProvider
-- （那个会加载各引擎的 provider，很重）。
----------------------------------------------------------------------

local EXTS = {
    epub = true, pdf = true, mobi = true, azw = true, azw3 = true,
    fb2 = true, fbz = true, fb2z = true, djvu = true,
    cbz = true, cbr = true, cb7 = true, cbt = true,
    txt = true, htm = true, html = true, xps = true,
    docx = true, rtf = true, chm = true,
}

local MAX_BOOKS = 200      -- 一次最多返回多少本，防止极端书库把手机端拖死
local MAX_DEPTH = 4        -- 目录递归深度
local SCAN_TTL = 60        -- 书目列表缓存秒数
local COVER_WIDTH = 260    -- 封面目标宽度（像素），手机端显示约 100-150 CSS px

----------------------------------------------------------------------
-- 模块加载
--
-- 这几个模块属于 KOReader 本体或 CoverBrowser 插件，插件运行时的
-- package.path 不一定含它们（取决于插件加载顺序），所以 require 失败时
-- 退回到按 DataDir 拼绝对路径 loadfile。全都失败就返回 nil 走降级。
----------------------------------------------------------------------

local BIM   -- BookInfoManager：封面/元数据 SQLite 缓存
local BFI   -- FileManagerBookInfo：现场抽封面的工具
local BL    -- BookList：阅读进度缓存

local function tryRequire(name)
    local ok, m = pcall(require, name)
    if ok and type(m) == "table" then return m end
    return nil
end

local function loadFromDisk(relpath)
    local ok, base = pcall(function() return DataStorage:getDataDir() end)
    if not ok or type(base) ~= "string" then return nil end
    local chunk = loadfile(base .. "/" .. relpath)
    if not chunk then return nil end
    local ok2, m = pcall(chunk)
    if ok2 and type(m) == "table" then return m end
    return nil
end

local function getBIM()
    if BIM ~= nil then return BIM or nil end
    BIM = tryRequire("bookinfomanager")
        or loadFromDisk("plugins/coverbrowser.koplugin/bookinfomanager.lua")
        or false
    return BIM or nil
end

local function getBFI()
    if BFI ~= nil then return BFI or nil end
    BFI = tryRequire("apps/filemanager/filemanagerbookinfo")
        or loadFromDisk("apps/filemanager/filemanagerbookinfo.lua")
        or false
    return BFI or nil
end

local function getBookList()
    if BL ~= nil then return BL or nil end
    BL = tryRequire("ui/widget/booklist")
        or loadFromDisk("ui/widget/booklist.lua")
        or false
    return BL or nil
end

----------------------------------------------------------------------
-- 路径与哈希
----------------------------------------------------------------------

-- djb2，够短够稳，用来做 URL 里的书籍标识和封面缓存文件名
local function hashPath(p)
    local h = 5381
    for i = 1, #p do
        h = (h * 33 + p:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

Library.hash = hashPath

local function joinPath(dir, name)
    if dir:sub(-1) == "/" then return dir .. name end
    return dir .. "/" .. name
end

local function extOf(name)
    local ext = name:match("%.([%w]+)$")
    return ext and ext:lower() or nil
end

local function basename(p)
    return (p:match("([^/]+)$") or p):gsub("%.[^./]+$", "")
end

----------------------------------------------------------------------
-- 缓存目录
----------------------------------------------------------------------

local cache_dir  -- nil = 还没算过，false = 不可用

local function getCacheDir()
    if cache_dir ~= nil then return cache_dir or nil end
    local ok, dir = pcall(function()
        return DataStorage:getSettingsDir() .. "/kremote_covers"
    end)
    if not ok or type(dir) ~= "string" then
        cache_dir = false
        return nil
    end
    local mode = lfs.attributes(dir, "mode")
    if mode ~= "directory" then
        local ffiUtil = tryRequire("ffi/util")
        local made = false
        if ffiUtil and type(ffiUtil.makePath) == "function" then
            made = pcall(ffiUtil.makePath, dir)
        end
        if not made then pcall(lfs.mkdir, dir) end
    end
    if lfs.attributes(dir, "mode") == "directory" then
        cache_dir = dir
        return dir
    end
    cache_dir = false
    return nil
end

----------------------------------------------------------------------
-- 最近阅读
--
-- 直接读 $DataDir/history.lua，不依赖 ReadHistory 单例是否已经 _read()
-- 过（插件刚起来时它可能是空的）。文件格式是 { {time=, file=}, ... }，
-- 已经按时间倒序。
----------------------------------------------------------------------

local function readHistory()
    local ok, base = pcall(function() return DataStorage:getDataDir() end)
    if not ok or type(base) ~= "string" then return {} end
    local chunk = loadfile(joinPath(base, "history.lua"))
    if not chunk then return {} end
    local ok2, data = pcall(chunk)
    if not ok2 or type(data) ~= "table" then return {} end
    return data
end

----------------------------------------------------------------------
-- 书目元数据
----------------------------------------------------------------------

-- hash -> path。书架缓存会过期，但用户点开一本书时 hash 必须还能解析回路径，
-- 所以这里单独记一份，只要这次运行扫到过就不会丢。
local SEEN = {}

-- 阅读进度：优先 BookList 的内存/磁盘缓存，失败再直接问 DocSettings
local function getPercent(path)
    local bl = getBookList()
    if bl and type(bl.getBookInfo) == "function" then
        local ok, info = pcall(bl.getBookInfo, path)
        if ok and type(info) == "table" and type(info.percent_finished) == "number" then
            return info.percent_finished
        end
    end
    local DocSettings = tryRequire("docsettings")
    if DocSettings then
        local ok, ds = pcall(DocSettings.open, DocSettings, path)
        if ok and ds then
            local ok2, pct = pcall(ds.readSetting, ds, "percent_finished")
            if ok2 and type(pct) == "number" then
                pcall(ds.close, ds)
                return pct
            end
            pcall(ds.close, ds)
        end
    end
    return nil
end

local function makeBook(path)
    local hash = hashPath(path)
    SEEN[hash] = path
    local title, authors, has_cover = nil, nil, false

    local bim = getBIM()
    if bim then
        -- get_cover = false：这里只要元数据，不在列表阶段解压封面 BLOB
        local ok, info = pcall(bim.getBookInfo, bim, path, false)
        if ok and type(info) == "table" then
            if info.ignore_meta ~= "Y" then
                title = info.title
                authors = info.authors
            end
            has_cover = info.has_cover == "Y"
        end
    end

    if type(title) ~= "string" or title == "" then title = basename(path) end
    if type(authors) ~= "string" then authors = "" end

    local pct = getPercent(path)
    -- percent_finished 是 0..1 的小数，没读过是 nil
    local percent = 0
    if type(pct) == "number" and pct >= 0 then
        percent = math.floor(math.min(pct, 1) * 1000 + 0.5) / 10
    end

    return {
        path = path,
        hash = hash,
        title = title,
        authors = authors,
        percent = percent,
        has_cover = has_cover,
    }
end

----------------------------------------------------------------------
-- 目录扫描
----------------------------------------------------------------------

local function skipDir(name)
    return name:sub(1, 1) == "." or name:sub(-4) == ".sdr"
end

local function walk(dir, out, depth)
    if depth > MAX_DEPTH or #out >= MAX_BOOKS then return end
    local ok, iter, state, init = pcall(lfs.dir, dir)
    if not ok or not iter then return end
    for entry in iter, state, init do
        if #out >= MAX_BOOKS then return end
        if entry ~= "." and entry ~= ".." then
            local full = joinPath(dir, entry)
            local mode = lfs.attributes(full, "mode")
            if mode == "directory" then
                if not skipDir(entry) then walk(full, out, depth + 1) end
            elseif mode == "file" then
                local ext = extOf(entry)
                if ext and EXTS[ext] then out[#out + 1] = full end
            end
        end
    end
end

local function getHomeDir()
    local ok, dir = pcall(function()
        return G_reader_settings:readSetting("home_dir")
    end)
    if ok and type(dir) == "string" and dir ~= ""
        and lfs.attributes(dir, "mode") == "directory" then
        return dir
    end
    local okd, base = pcall(function() return DataStorage:getDataDir() end)
    if not okd or type(base) ~= "string" then return nil end
    return joinPath(base, "documents")
end

----------------------------------------------------------------------
-- 对外：书目列表
----------------------------------------------------------------------

local scan_cache = { time = 0, data = nil }

local function now()
    local ok, t = pcall(os.time)
    return (ok and t) or 0
end

--- 返回 { recent = {...}, books = {...} }
--- recent 是最近阅读的前 3 本（与 books 里的条目是同一结构）
function Library.shelf(force)
    local t = now()
    if not force and scan_cache.data and (t - scan_cache.time) < SCAN_TTL then
        return scan_cache.data
    end

    local books, by_path = {}, {}
    local home = getHomeDir()
    if home then
        local paths = {}
        walk(home, paths, 1)
        for _, p in ipairs(paths) do
            local b = makeBook(p)
            books[#books + 1] = b
            by_path[p] = b
        end
    end

    -- 按书名排序（Kindle 上 lfs 返回的是目录项顺序，不做排序会很乱）
    table.sort(books, function(a, b)
        local ta, tb = a.title:lower(), b.title:lower()
        if ta == tb then return a.path < b.path end
        return ta < tb
    end)

    -- 最近阅读：按 history 顺序取前 3 个还存在的文件
    local recent = {}
    for _, item in ipairs(readHistory()) do
        if #recent >= 3 then break end
        local p = type(item) == "table" and item.file or nil
        if type(p) == "string" and lfs.attributes(p, "mode") == "file" then
            -- 书目列表里没有（比如在书库目录之外）就现场补一条
            local b = by_path[p] or makeBook(p)
            recent[#recent + 1] = b
        end
    end

    local data = { recent = recent, books = books }
    scan_cache = { time = t, data = data }
    return data
end

function Library.invalidate()
    scan_cache = { time = 0, data = nil }
end

----------------------------------------------------------------------
-- 封面
----------------------------------------------------------------------

local cover_mem = {}        -- hash -> jpeg bytes（内存缓存，重启失效）
local MEM_LIMIT = 40        -- 最多缓存多少张，超了整体清空（够用且简单）

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- 缓存文件比书新才算有效；书被替换/重新下载后自动重新生成
local function cacheFresh(cache_path, book_path)
    local cm = lfs.attributes(cache_path, "modification")
    if not cm then return false end
    local bm = lfs.attributes(book_path, "modification")
    if not bm then return false end
    return cm >= bm
end

-- 缓存文件可能是 .jpg 也可能是 .png（JPEG 编码失败的机器会退到 PNG），
-- 两种都要能找回来
local function findCacheFile(dir, hash)
    for _, ext in ipairs({ "jpg", "png" }) do
        local p = joinPath(dir, hash .. "." .. ext)
        if lfs.attributes(p, "modification") then return p, ext end
    end
    return nil, nil
end

local function ctypeOf(data)
    -- JPEG: FF D8 FF；PNG: 89 50 4E 47
    if #data >= 8 and data:byte(1) == 0x89 and data:byte(2) == 0x50 then
        return "image/png"
    end
    return "image/jpeg"
end

-- 从 CoverBrowser 的 SQLite 里取封面 BlitBuffer；没有就现场抽一张
local function getCoverBB(path)
    local bim = getBIM()
    if bim then
        local ok, info = pcall(bim.getBookInfo, bim, path, true)
        if ok and type(info) == "table" then
            if info.ignore_cover == "Y" then return nil end
            if info.cover_bb then return info.cover_bb end
            if info.has_cover == "Y" then
                -- 库里有标记但 BLOB 没解出来，交给下方现场抽取兜底
            elseif info.cover_fetched == "Y" then
                -- 已经试过且没有封面，不用再浪费时间
                return nil
            end
        end
    end

    -- 现场抽取。只对"还没有记录"的书走到这里，抽完落盘缓存，下次不再走。
    local bfi_mod = getBFI()
    if not bfi_mod then return nil end
    local ok2, inst = pcall(function() return bfi_mod:new{} end)
    if not ok2 or not inst then return nil end
    local ok3, bb = pcall(inst.getCoverImage, inst, nil, path)
    if ok3 then return bb end
    return nil
end

--- 返回 图片二进制, content_type；失败返回 nil
function Library.cover(path)
    if type(path) ~= "string" or path == "" then return nil end
    local hash = hashPath(path)

    local cached = cover_mem[hash]
    if cached then return cached, ctypeOf(cached) end

    local dir = getCacheDir()

    -- 磁盘缓存：命中就直接回，省掉一次 zstd 解压 + 缩放 + 编码
    if dir then
        local cache_path = findCacheFile(dir, hash)
        if cache_path and cacheFresh(cache_path, path) then
            local data = readFile(cache_path)
            if data and #data > 0 then
                cover_mem[hash] = data
                return data, ctypeOf(data)
            end
        end
    end

    local bb = getCoverBB(path)
    if not bb then return nil end

    -- 缩到手机端够用的宽度再编码：原图往往是 1000x1500，编码慢、传输大
    local okw, w = pcall(bb.getWidth, bb)
    local okh, h = pcall(bb.getHeight, bb)
    if not okw or not okh or type(w) ~= "number" or type(h) ~= "number"
        or w <= 0 or h <= 0 then
        return nil
    end
    if w > COVER_WIDTH then
        local nh = math.max(1, math.floor(h * COVER_WIDTH / w + 0.5))
        local oks, scaled = pcall(bb.scale, bb, COVER_WIDTH, nh)
        if oks and scaled then bb = scaled end
    end

    local data
    if dir then
        local tmp = joinPath(dir, hash .. ".tmp")
        -- 先 JPEG（体积小、编码快），失败退 PNG（无损但更大）
        for _, ext in ipairs({ "jpg", "png" }) do
            pcall(os.remove, tmp)
            local oke, done = pcall(bb.writeToFile, bb, tmp, ext, 85)
            if oke and done then
                local got = readFile(tmp)
                if got and #got > 0 then
                    local target = joinPath(dir, hash .. "." .. ext)
                    -- 另一种格式的旧文件可能还在，清掉免得 findCacheFile 读错
                    local other = joinPath(dir, hash .. "." .. (ext == "jpg" and "png" or "jpg"))
                    pcall(os.remove, other)
                    pcall(os.remove, target)
                    local okr, renamed = pcall(os.rename, tmp, target)
                    if okr and renamed then data = got end
                end
            end
            pcall(os.remove, tmp)
            if data then break end
        end
    end

    if not data then return nil end

    local n = 0
    for _ in pairs(cover_mem) do n = n + 1 end
    if n > MEM_LIMIT then cover_mem = {} end
    cover_mem[hash] = data
    return data, ctypeOf(data)
end

----------------------------------------------------------------------
-- 查找
----------------------------------------------------------------------

function Library.findByHash(hash)
    if type(hash) ~= "string" then return nil end
    local p = SEEN[hash]
    if p and lfs.attributes(p, "mode") == "file" then return p end
    -- 这次运行还没扫到（比如插件刚起来）：触发一次扫描再找
    local data = Library.shelf(false)
    for _, b in ipairs(data.books) do
        if b.hash == hash then return b.path end
    end
    for _, b in ipairs(data.recent) do
        if b.hash == hash then return b.path end
    end
    return SEEN[hash]
end

function Library.basename(p)
    return basename(p)
end

return Library
