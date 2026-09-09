"""Local Web export server with COOP/COEP headers (SharedArrayBuffer).

用法: python tools/serve_web_coop.py [dir=build/web] [port=8765]
Godot 4 Web 默认需要 SharedArrayBuffer → 必须 cross-origin-isolated。
"""

import os
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class CoopHandler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()

    def log_message(self, fmt, *args):
        pass


def main() -> None:
    target = sys.argv[1] if len(sys.argv) > 1 else "build/web"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8765
    os.chdir(target)
    print(f"serving {os.getcwd()} on http://127.0.0.1:{port} with COOP/COEP")
    ThreadingHTTPServer(("127.0.0.1", port), CoopHandler).serve_forever()


if __name__ == "__main__":
    main()
