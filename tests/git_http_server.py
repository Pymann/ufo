#!/usr/bin/env python3
"""A smart-HTTP git server for the tests: `git http-backend` behind http.server.

    python3 tests/git_http_server.py <port> <project_root> [<user>:<password>]

Every repository below <project_root> is served at /<name>.git/…; push is
allowed (REMOTE_USER is set).  With credentials, every request needs HTTP
Basic auth with them (401 otherwise).  Logs one line per request to stderr.
"""
import base64
import http.server
import os
import subprocess
import sys

PORT = int(sys.argv[1])
ROOT = sys.argv[2]
CREDS = sys.argv[3] if len(sys.argv) > 3 else ""


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def handle_any(self):
        if CREDS:
            want = "Basic " + base64.b64encode(CREDS.encode()).decode()
            if self.headers.get("Authorization", "") != want:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="git"')
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        path, _, query = self.path.partition("?")
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        env = dict(os.environ)
        env.update({
            "GIT_PROJECT_ROOT": ROOT,
            "GIT_HTTP_EXPORT_ALL": "1",
            "REQUEST_METHOD": self.command,
            "PATH_INFO": path,
            "QUERY_STRING": query,
            "CONTENT_TYPE": self.headers.get("Content-Type", ""),
            "CONTENT_LENGTH": str(len(body)),
            "REMOTE_USER": "tester",
            "REMOTE_ADDR": "127.0.0.1",
            "GIT_PROTOCOL": self.headers.get("Git-Protocol", ""),
            "HTTP_GIT_PROTOCOL": self.headers.get("Git-Protocol", ""),
        })
        proc = subprocess.run(["git", "http-backend"], input=body, env=env, capture_output=True)
        out = proc.stdout
        head, _, payload = out.partition(b"\r\n\r\n")
        if not _:
            head, _, payload = out.partition(b"\n\n")
        status = 200
        headers = []
        for line in head.decode("latin-1").splitlines():
            if not line.strip():
                continue
            key, _, value = line.partition(":")
            if key.lower() == "status":
                status = int(value.strip().split()[0])
            else:
                headers.append((key.strip(), value.strip()))
        self.send_response(status)
        for key, value in headers:
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = handle_any
    do_POST = handle_any


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
