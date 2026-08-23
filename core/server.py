#!/usr/bin/env python3
"""
Mimic — clone your voice, type something, hear yourself say it.

    python3 -m core.server              # then open http://127.0.0.1:8455
    python3 -m core.server --setup      # download the model and exit

Everything runs on this machine. The HTTP API below is the only interface the
apps use, so the browser, the macOS app and anything else added later are all
looking at the same engine.

    GET  /api/voices                 the library
    POST /api/voices                 register one   {name, wav_hex, transcript}
    POST /api/voices/<name>/rename   {name}
    DELETE /api/voices/<name>
    GET  /api/voices/<name>/sample.wav
    POST /api/speak                  {text, voice, seed?} -> audio/wav
    GET  /api/health
"""

from __future__ import annotations

import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import engine as core

HERE = Path(__file__).resolve().parent
WEB = HERE.parent / "web"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    engine: core.Engine

    def log_message(self, *args):
        pass

    # ---- plumbing ----

    def reply(self, code, payload, content_type="application/json", **headers):
        if isinstance(payload, (dict, list)):
            payload = json.dumps(payload)
        data = payload.encode() if isinstance(payload, str) else payload
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        for name, value in headers.items():
            self.send_header(name.replace("_", "-"), value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def body(self):
        length = int(self.headers.get("Content-Length", 0))
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length))
        except ValueError:
            return None

    def fail(self, code, message):
        self.reply(code, {"error": message})

    # ---- routes ----

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            return self.send_web("index.html", "text/html; charset=utf-8")
        if path == "/api/health":
            return self.reply(200, {
                "ok": True,
                "model_ready": core.model_ready(),
                "model_loaded": self.engine.loaded,
                "voices": len(self.engine.voices()),
                "sample_rate": core.SAMPLE_RATE,
            })
        if path == "/api/voices":
            return self.reply(200, {"voices": self.engine.voices()})
        if path.startswith("/api/voices/") and path.endswith("/sample.wav"):
            data = self.engine.sample(_name_from(path))
            if data is None:
                return self.fail(404, "no recording kept for that voice")
            return self.reply(200, data, "audio/wav", Cache_Control="no-store")
        self.fail(404, "not found")

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        path = self.path.split("?")[0]
        payload = self.body()
        if payload is None:
            return self.fail(400, "malformed JSON")

        if path == "/api/voices":
            return self.register(payload)
        if path.startswith("/api/voices/") and path.endswith("/rename"):
            old, new = _name_from(path), (payload.get("name") or "").strip()
            if not new:
                return self.fail(400, "a name is required")
            if not self.engine.rename(old, new):
                return self.fail(409, "could not rename — does the new name already exist?")
            return self.reply(200, {"ok": True, "voices": self.engine.voices()})
        if path == "/api/speak":
            return self.speak(payload)
        self.fail(404, "not found")

    def do_DELETE(self):
        path = self.path.split("?")[0]
        if path.startswith("/api/voices/"):
            if not self.engine.delete(_name_from(path, tail=0)):
                return self.fail(404, "no such voice")
            return self.reply(200, {"ok": True, "voices": self.engine.voices()})
        self.fail(404, "not found")

    # ---- handlers ----

    def register(self, payload):
        name = (payload.get("name") or "").strip()
        transcript = " ".join((payload.get("transcript") or "").split())
        if not name or not transcript:
            return self.fail(400, "a name and the transcript are both required")
        try:
            wav = bytes.fromhex(payload.get("wav_hex", ""))
        except ValueError:
            return self.fail(400, "audio was not valid hex")

        started = time.time()
        try:
            self.engine.register(name, wav, transcript)
        except core.ModelMissing as exc:
            return self.fail(503, str(exc))
        except (ValueError, RuntimeError, FileExistsError) as exc:
            return self.fail(400, str(exc))
        log(f"registered {name!r} in {time.time() - started:.1f}s")
        self.reply(200, {"ok": True, "voices": self.engine.voices()})

    def speak(self, payload):
        try:
            data, seconds, cached = self.engine.speak(
                text=payload.get("text", ""),
                voice=payload.get("voice", ""),
                seed=int(payload.get("seed", 42)))
        except core.ModelMissing as exc:
            return self.fail(503, str(exc))
        except ValueError as exc:
            return self.fail(400, str(exc))
        self.reply(200, data, "audio/wav",
                   X_Mimic_Cached="1" if cached else "0",
                   X_Mimic_Seconds=f"{seconds:.2f}")

    def send_web(self, name, content_type):
        try:
            with open(WEB / name, "rb") as handle:
                data = handle.read()
        except OSError:
            return self.fail(404, f"{name} is missing")
        self.reply(200, data, content_type, Cache_Control="no-store")


def _name_from(path, tail=1):
    """The voice name out of /api/voices/<name>[/something]."""
    parts = [p for p in path.split("/") if p]
    return parts[2] if len(parts) > 2 else ""


def log(message):
    print(f"  {message}", flush=True)


def main():
    parser = argparse.ArgumentParser(description="Mimic — your voice, on your machine.")
    parser.add_argument("--port", type=int, default=8455)
    parser.add_argument("--host", default="127.0.0.1",
                        help="0.0.0.0 to reach it from another device on your network")
    parser.add_argument("--threads", type=int, default=5)
    parser.add_argument("--setup", action="store_true",
                        help="Download the model and exit.")
    parser.add_argument("--keep-loaded", action="store_true",
                        help="Never unload the model; faster, at about a gigabyte of RAM.")
    args = parser.parse_args()

    if args.setup:
        core.download()
        return

    if not core.model_ready():
        print("\nThe model has not been downloaded yet. Run:\n")
        print("    python3 -m core.server --setup\n")
        raise SystemExit(1)

    Handler.engine = core.Engine(
        threads=args.threads, idle_unload=0 if args.keep_loaded else core.IDLE_UNLOAD_SECONDS)
    voices = Handler.engine.voices()

    print(f"\nMimic  ->  http://{args.host}:{args.port}")
    if voices:
        for entry in voices:
            print(f"  · {entry['name']}")
    else:
        print("  no voices yet — record one on the page above")
    print("\nCtrl-C to stop.\n")
    try:
        ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
    except KeyboardInterrupt:
        print()


if __name__ == "__main__":
    main()
