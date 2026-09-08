#!/usr/bin/env python3
"""Model-free regression coverage for the native HTTP client."""
import json
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    voices = ["Me 100% #? café", "Other"]
    cache = 300

    def log_message(self, *_):
        pass

    def reply(self, code, payload):
        data = json.dumps(payload).encode() if isinstance(payload, dict) else payload
        self.send_response(code)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(data)

    @property
    def parts(self):
        return [urllib.parse.unquote(part) for part in urllib.parse.urlsplit(self.path).path.split("/") if part]

    def do_GET(self):
        if self.path == "/api/health":
            return self.reply(200, {"ok": True, "capabilities": ["storage"]})
        if self.path == "/api/voices":
            return self.reply(200, {"voices": [{"name": name} for name in self.voices]})
        if self.path == "/api/storage":
            return self.reply(200, {"model": 100, "voices": 200, "cache": self.cache, "total": 300 + self.cache})
        if self.parts[:2] == ["api", "voices"] and self.parts[-1] == "sample.wav":
            name = self.parts[2]
            if name in self.voices:
                return self.reply(200, name.encode())
        self.reply(404, {"error": "not found"})

    def do_DELETE(self):
        if self.path == "/api/cache":
            type(self).cache = 0
        elif len(self.parts) == 3 and self.parts[:2] == ["api", "voices"]:
            self.voices.remove(self.parts[2])
        else:
            return self.reply(404, {"error": "not found"})
        self.reply(200, {"ok": True})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        if self.parts[:2] == ["api", "voices"] and self.parts[-1] == "rename":
            self.voices[self.voices.index(self.parts[2])] = body["name"]
            return self.reply(200, {"ok": True})
        if self.path == "/api/model/unload":
            return self.reply(200, {"ok": True})
        text = body["text"]
        if text == "http-error":
            return self.reply(409, {"error": "A useful conflict message"})
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.line({"type": "start", "sample_rate": 44100})
            if text == "stream-error":
                return self.line({"type": "error", "message": "Model unavailable"})
            if text == "cancel":
                time.sleep(0.4)
            self.line({"type": "chunk", "index": 0, "pcm": "AIAAQA=="})
            if text != "truncated":
                self.line({"type": "done"})
        except (BrokenPipeError, ConnectionResetError):
            pass

    def line(self, payload):
        self.wfile.write(json.dumps(payload).encode() + b"\n")
        self.wfile.flush()


def main():
    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    binary = build / "engine-regression"
    subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(build / "module-cache"),
                    str(ROOT / "Sources/Engine.swift"), str(ROOT / "Tests/EngineRegression.swift"),
                    "-o", str(binary)], check=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run([str(binary), str(server.server_port)], check=True, timeout=30)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
