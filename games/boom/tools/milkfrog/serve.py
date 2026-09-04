"""dev server: static files + Cache-Control no-store（迭代期避免模块缓存）
另提供 POST /save?name=<file>：把浏览器导出的 GLB blob 落盘到 exports/，
用于无头环境验证导出功能（无头浏览器会取消程序化下载）。"""
import os
import re
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
EXPORTS = os.path.join(BASE, "exports")


class NoStore(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, max-age=0")
        super().end_headers()

    def log_message(self, *a):
        pass

    def do_POST(self):
        name = re.sub(r"[^\w.\-]", "_", self.path.split("name=")[-1] or "out.glb")
        length = int(self.headers.get("Content-Length", 0))
        data = self.rfile.read(length)
        os.makedirs(EXPORTS, exist_ok=True)
        with open(os.path.join(EXPORTS, name), "wb") as f:
            f.write(data)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(("saved %d bytes -> exports/%s" % (len(data), name)).encode())


if __name__ == "__main__":
    os.chdir(BASE)
    ThreadingHTTPServer(("127.0.0.1", 8788), NoStore).serve_forever()
