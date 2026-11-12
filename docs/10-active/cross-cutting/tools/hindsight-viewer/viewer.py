"""Hindsight 只读查看器的本地服务。

分类：只测试（Test-only）。只读：只把 GET 原样转发给 Hindsight，其他方法一律 405。
不是分发运行时依赖，不进任何打包产物。只用 Python 标准库。

用法：python -B viewer.py [--hindsight http://127.0.0.1:18931] [--port 18940]
"""

import argparse
import json
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

INDEX = Path(__file__).with_name("index.html")
TIMEOUT_S = 15


class Handler(BaseHTTPRequestHandler):
    upstream = ""

    def _send(self, status, body, ctype="text/plain; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(200, INDEX.read_bytes(), "text/html; charset=utf-8")
            return
        if self.path == "/viewer-info":
            self._send(200, json.dumps({"hindsight": self.upstream}).encode(), "application/json")
            return
        if not self.path.startswith("/api/"):
            self._send(404, "未找到".encode())
            return
        url = self.upstream + self.path[len("/api"):]
        req = urllib.request.Request(url, method="GET", headers={"Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
                self._send(resp.status, resp.read(), resp.headers.get("Content-Type", "application/json"))
        except urllib.error.HTTPError as e:
            self._send(e.code, f"Hindsight 返回 {e.code}：{e.read()[:500].decode('utf-8', 'replace')}".encode())
        except Exception as e:  # 连不上、超时等：上游没有状态码，按网关错误回
            self._send(502, f"无法访问 Hindsight（{self.upstream}）：{e}".encode())

    def _reject(self):
        self._send(405, "只读查看器：只允许 GET".encode())

    do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = _reject

    def log_message(self, fmt, *args):
        print("%s %s" % (self.command, self.path), flush=True)


def main():
    ap = argparse.ArgumentParser(description="Hindsight 只读查看器（只测试）")
    ap.add_argument("--hindsight", default="http://127.0.0.1:18931")
    ap.add_argument("--port", type=int, default=18940)
    args = ap.parse_args()
    Handler.upstream = args.hindsight.rstrip("/")
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"查看器：http://127.0.0.1:{args.port}/  →  Hindsight：{Handler.upstream}（只转发 GET）", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
