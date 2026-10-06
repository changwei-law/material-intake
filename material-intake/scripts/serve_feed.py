# -*- coding: utf-8 -*-
"""本机日历订阅小服务：把指定目录以 http://127.0.0.1:<port>/ 提供出去。

只监听本机回环地址，不对外网开放。.ics 文件按 text/calendar 返回，供 Thunderbird
等桌面日历客户端订阅。

用法：python serve_feed.py <目录> [端口]
"""
import http.server
import socketserver
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 2:
        print("用法：python serve_feed.py <目录> [端口]")
        return 2
    directory = Path(sys.argv[1]).expanduser().resolve()
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8799
    directory.mkdir(parents=True, exist_ok=True)

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(directory), **kwargs)

        def guess_type(self, path):
            if str(path).lower().endswith((".ics", ".ifb")):
                return "text/calendar; charset=utf-8"
            return super().guess_type(path)

        def log_message(self, *args):
            try:
                import datetime
                try:
                    message = args[0] % args[1:]
                except Exception:
                    message = " ".join(str(a) for a in args)
                line = "%s  %s  %s\n" % (
                    datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                    self.client_address[0],
                    message,
                )
                with open(directory / "访问日志.txt", "a", encoding="utf-8") as handle:
                    handle.write(line)
            except Exception:
                pass

    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    with Server(("127.0.0.1", port), Handler) as httpd:
        print("服务已启动：http://127.0.0.1:%d/  →  %s" % (port, directory), flush=True)
        httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
