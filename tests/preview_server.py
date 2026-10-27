#!/usr/bin/env python3
"""本地预览服务：不用 Kindle，在电脑浏览器里改面板样式。

    python3 tests/preview_server.py            # http://127.0.0.1:8099
    python3 tests/preview_server.py 9000       # 换端口

直接读同目录上一层的 panel.html，所以改完刷新浏览器就能看到效果。
假数据覆盖了两种状态：

    /                 书架页（Kindle 在书架）
    /?view=reader     控制页（Kindle 正在看书）
    /api/*            与真机同名的接口，返回假数据

封面是现场生成的纯色 PNG，用来检查比例和排版，不是真书封。
"""

import json
import os
import struct
import sys
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PLUGIN = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ── 假数据 ───────────────────────────────────────────────────


def png(w, h, rgb):
    """生成一张纯色 PNG，省掉图片依赖。"""
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6))
            + chunk(b"IEND", b""))


COLORS = [(58, 92, 120), (120, 62, 62), (74, 96, 64), (96, 74, 118),
          (118, 96, 58), (58, 104, 104), (104, 58, 92), (70, 70, 110)]

RECENT = [
    {"h": "aaa00001", "t": "三体", "a": "刘慈欣", "p": 42.3, "c": 1},
    {"h": "aaa00002", "t": "活着", "a": "余华", "p": 100.0, "c": 1},
    {"h": "aaa00003", "t": "百年孤独", "a": "加西亚·马尔克斯", "p": 7.8, "c": 1},
]

NAMES = ["三体", "活着", "百年孤独", "人类简史：从动物到上帝", "明朝那些事儿",
         "The Three-Body Problem", "深入理解计算机系统", "看不见的城市",
         "红楼梦", "围城"]

BOOKS = [{"h": "bbb%05d" % i, "t": n, "a": "作者", "p": (i * 13.7) % 100, "c": 1}
         for i, n in enumerate(NAMES)]

ALL = RECENT + BOOKS


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, code, ctype, body, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj):
        self._send(200, "application/json", json.dumps(obj).encode())

    def do_GET(self):
        u = urlparse(self.path)
        path, q = u.path, parse_qs(u.query)
        view = "reader" if (q.get("view") or [""])[0] == "reader" else "shelf"

        if path == "/":
            with open(os.path.join(PLUGIN, "panel.html"), "rb") as f:
                return self._send(200, "text/html; charset=utf-8", f.read())

        if path == "/api/state":
            return self._json({"ok": 1, "view": view, "battery": 76, "charging": 0})

        if path == "/api/shelf":
            return self._json({"ok": 1, "view": view, "battery": 76, "charging": 0,
                               "recent": RECENT, "books": BOOKS})

        if path == "/api/status":
            return self._json({"ok": 1, "view": view, "title": "三体", "authors": "刘慈欣",
                               "page": 142, "pages": 336, "percent": 42.3,
                               "battery": 76, "charging": 0, "night": 0,
                               "light": 12, "lightmax": 24})

        if path == "/api/cover":
            h = (q.get("h") or [""])[0]
            idx = next((i for i, b in enumerate(ALL) if b["h"] == h), 0)
            return self._send(200, "image/png", png(260, 390, COLORS[idx % len(COLORS)]))

        if path in ("/api/open", "/api/home", "/api/night", "/api/refresh",
                    "/api/next", "/api/prev", "/api/font_inc", "/api/font_dec",
                    "/api/chapter_next", "/api/chapter_prev", "/api/light"):
            return self._json({"ok": 1})

        return self._send(404, "text/plain; charset=utf-8", b"not found")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
    print("preview: http://127.0.0.1:%d/  (?view=reader 看控制页)" % port)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
