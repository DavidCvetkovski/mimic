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
    GET  /api/presets                shared writing prompts
    GET  /api/storage                model, voices, cache and total bytes
    DELETE /api/cache                clear generated audio
    POST /api/model/unload          release model memory
"""

from __future__ import annotations

import argparse
import contextlib
import ipaddress
import json
import os
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import engine as core

HERE = Path(__file__).resolve().parent
WEB = HERE.parent / "web"
MAX_BODY_BYTES = core.MAX_AUDIO_BYTES * 2 + 1024 * 1024


class RequestError(ValueError):
    def __init__(self, message, code=400):
        super().__init__(message)
        self.code = code


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
        self.send_header("X-Content-Type-Options", "nosniff")
        if "Cache_Control" not in headers:
            self.send_header("Cache-Control", "no-store")
        for name, value in headers.items():
            self.send_header(name.replace("_", "-"), value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def body(self):
        if self.headers.get("Transfer-Encoding"):
            raise RequestError("chunked request bodies are not supported")
        lengths = self.headers.get_all("Content-Length", [])
        if len(lengths) > 1:
            raise RequestError("only one Content-Length is allowed")
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            raise RequestError("invalid Content-Length") from None
        if length < 0:
            raise RequestError("invalid Content-Length")
        if length > MAX_BODY_BYTES:
            raise RequestError("request is too large; audio must be at most 50 MiB", 413)
        if not length:
            return {}
        kind = self.headers.get_content_type()
        if kind != "application/json":
            raise RequestError("send the request as application/json", 415)
        try:
            self.connection.settimeout(30)
            data = self.rfile.read(length)
        except TimeoutError:
            raise RequestError("request body timed out", 408) from None
        finally:
            self.connection.settimeout(None)
        if len(data) != length:
            raise RequestError("incomplete request body")
        try:
            payload = json.loads(data)
        except (ValueError, RecursionError):
            raise RequestError("malformed JSON") from None
        if not isinstance(payload, dict):
            raise RequestError("JSON body must be an object")
        return payload

    def fail(self, code, message):
        self.reply(code, {"error": message})

    def dispatch(self, action):
        try:
            address = self.server.server_address[0]
            host = urllib.parse.urlsplit("//" + self.headers.get("Host", "")).hostname
            if ipaddress.ip_address(address).is_loopback:
                try:
                    local_host = (
                        host == "localhost" or ipaddress.ip_address(host or "").is_loopback
                    )
                except ValueError:
                    local_host = False
                if not local_host:
                    raise RequestError(
                        "use localhost or a loopback address to reach this server", 403
                    )
            # A local server is reachable from arbitrary websites. Accept
            # browser requests only from its own origin; native apps omit it.
            origin = self.headers.get("Origin")
            if origin:
                parsed = urllib.parse.urlsplit(origin)
                if (parsed.scheme not in {"http", "https"}
                        or parsed.netloc.lower() != self.headers.get("Host", "").lower()):
                    raise RequestError("requests must come from this Mimic server", 403)
            # A link from the hosted vault may open the studio document. It
            # must not grant cross-site access to APIs, files, or mutations.
            studio_navigation = (
                self.command == "GET"
                and self.path.split("?")[0] in {"/", "/index.html"}
                and self.headers.get("Sec-Fetch-Mode") == "navigate"
                and self.headers.get("Sec-Fetch-Dest") == "document"
            )
            if self.headers.get("Sec-Fetch-Site") == "cross-site" and not studio_navigation:
                raise RequestError("cross-site requests are not allowed", 403)
            action()
        except RequestError as exc:
            self.close_connection = True
            self.fail(exc.code, str(exc))
        except core.ModelMissing as exc:
            self.fail(503, str(exc))
        except FileExistsError as exc:
            self.fail(409, str(exc))
        except ValueError as exc:
            self.fail(400, str(exc))
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True
        except Exception as exc:  # noqa: BLE001
            log(f"request failed: {exc}")
            self.fail(
                500,
                "The engine could not complete this request. "
                "Check the server log and try again.",
            )

    # ---- routes ----

    def do_GET(self):
        self.dispatch(self.get_route)

    def get_route(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            return self.send_web("index.html", "text/html; charset=utf-8")
        if path.startswith("/assets/"):
            name = path.split("/")[-1]
            kinds = {".svg": "image/svg+xml", ".png": "image/png",
                     ".js": "text/javascript; charset=utf-8",
                     ".css": "text/css; charset=utf-8", ".json": "application/json"}
            kind = kinds.get(os.path.splitext(name)[1])
            if kind and "/" not in name and ".." not in name:
                return self.send_web("assets/" + name, kind)
            return self.fail(404, "not found")
        if path == "/api/health":
            return self.reply(200, {
                "ok": True,
                "streaming": True,
                "model_ready": core.model_ready(),
                "model_loaded": self.engine.loaded,
                "voices": len(self.engine.voices()),
                "sample_rate": core.SAMPLE_RATE,
                "api_version": 1,
                "capabilities": ["streaming", "presets", "storage", "cache", "unload"],
                "limits": {"text_characters": core.MAX_TEXT_CHARACTERS,
                           "voice_characters": core.MAX_VOICE_CHARACTERS,
                           "audio_bytes": core.MAX_AUDIO_BYTES},
            })
        if path == "/api/presets":
            return self.reply(200, {"presets": json.loads((HERE / "presets.json").read_text())})
        if path == "/api/storage":
            return self.reply(200, self.engine.storage())
        if path.startswith("/api/voices/") and path.endswith("/export"):
            from .voice_transfer import export_voice
            with self.engine._lock:
                data = export_voice(core.VOICES_DIR, _name_from(path))
            return self.reply(200, data, "application/json")
        if path == "/api/voices":
            return self.reply(200, {"voices": self.engine.voices()})
        name = _voice_route(path, "sample.wav")
        if name is not None:
            data = self.engine.sample(name)
            if data is None:
                return self.fail(404, "no recording kept for that voice")
            return self.reply(200, data, "audio/wav", Cache_Control="no-store")
        self.fail(404, "not found")

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        self.dispatch(self.post_route)

    def post_route(self):
        path = self.path.split("?")[0]
        payload = self.body()

        if path == "/api/voices/import":
            from .voice_transfer import import_voice
            with self.engine._lock:
                name = import_voice(core.VOICES_DIR, json.dumps(payload).encode())
                self.engine._runtime = None
                self.engine._forget_cached(name)
            return self.reply(200, {"ok": True, "name": name})
        if path == "/api/voices":
            return self.register(payload)
        old = _voice_route(path, "rename")
        if old is not None:
            new = _string(payload, "name").strip()
            core.validate_voice_name(old)
            core.validate_voice_name(new)
            if not self.engine.rename(old, new):
                return self.fail(409, "could not rename — does the new name already exist?")
            return self.reply(200, {"ok": True, "voices": self.engine.voices()})
        if path == "/api/speak":
            return self.speak(payload)
        if path == "/api/speak/stream":
            return self.speak_stream(payload)
        if path == "/api/model/unload":
            self.engine.unload()
            return self.reply(200, {"ok": True, "model_loaded": self.engine.loaded})
        self.fail(404, "not found")

    def do_DELETE(self):
        self.dispatch(self.delete_route)

    def delete_route(self):
        path = self.path.split("?")[0]
        if path == "/api/cache":
            self.engine.clear_cache()
            return self.reply(200, {"ok": True, "storage": self.engine.storage()})
        name = _voice_route(path)
        if name is not None:
            core.validate_voice_name(name)
            if not self.engine.delete(name):
                return self.fail(404, "no such voice")
            return self.reply(200, {"ok": True, "voices": self.engine.voices()})
        self.fail(404, "not found")

    # ---- handlers ----

    def register(self, payload):
        name = _string(payload, "name").strip()
        raw_transcript = _string(payload, "transcript")
        if len(raw_transcript) > core.MAX_TEXT_CHARACTERS:
            raise RequestError(
                f"transcript must be at most {core.MAX_TEXT_CHARACTERS:,} characters"
            )
        transcript = " ".join(raw_transcript.split())
        if not name or not transcript:
            return self.fail(400, "a name and the transcript are both required")
        try:
            wav = bytes.fromhex(_string(payload, "wav_hex"))
        except ValueError:
            return self.fail(400, "audio was not valid hex")

        started = time.time()
        try:
            self.engine.register(
                name, wav, transcript, overwrite=payload.get("overwrite", False)
            )
        except core.ModelMissing as exc:
            return self.fail(503, str(exc))
        except FileExistsError as exc:
            return self.fail(409, str(exc))
        except (ValueError, RuntimeError) as exc:
            return self.fail(400, str(exc))
        log(f"registered {name!r} in {time.time() - started:.1f}s")
        self.reply(200, {"ok": True, "voices": self.engine.voices()})

    def speak(self, payload):
        try:
            data, seconds, cached = self.engine.speak(
                text=payload.get("text", ""),
                voice=payload.get("voice", ""),
                seed=payload.get("seed", 42))
        except core.ModelMissing as exc:
            return self.fail(503, str(exc))
        except ValueError as exc:
            return self.fail(400, str(exc))
        self.reply(200, data, "audio/wav",
                   X_Mimic_Cached="1" if cached else "0",
                   X_Mimic_Seconds=f"{seconds:.2f}")

    def speak_stream(self, payload):
        """
        Stream the audio a sentence at a time, as newline-delimited JSON.

        One object per line, so a browser reads it with a plain fetch reader and
        no framing of its own. The opening line carries the length estimate; each
        chunk carries how fast generation is actually running, which is what lets
        the page decide when it has buffered enough to play without catching up.
        """
        import base64

        text = _string(payload, "text")
        voice = _string(payload, "voice")
        seed = payload.get("seed", 42)

        try:
            stream = self.engine.speak_stream(text=text, voice=voice, seed=seed)
        except core.ModelMissing as exc:
            return self.fail(503, str(exc))
        except ValueError as exc:
            return self.fail(400, str(exc))

        import numpy as np

        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.close_connection = True

        def line(event):
            self.wfile.write((json.dumps(event) + "\n").encode())
            self.wfile.flush()

        started = time.time()
        try:
            line({"type": "start",
                  "estimate": round(self.engine.estimate(text), 2),
                  "sentences": len(core.split_sentences(" ".join(text.split()))),
                  "sample_rate": core.SAMPLE_RATE})
            for event in stream:
                if event["done"]:
                    line({"type": "done",
                          "seconds": round(event["seconds"], 2),
                          "cached": event["cached"],
                          "elapsed": round(time.time() - started, 2),
                          # A cache hit produced no chunks, so hand the whole
                          # thing over rather than leaving the page silent.
                          "wav": base64.b64encode(event["wav"]).decode()
                                 if event["cached"] else None})
                    break
                pcm = (np.clip(event["samples"], -1, 1) * 32767).astype("<i2")
                line({"type": "chunk",
                      "index": event["index"], "of": event["of"],
                      "seconds": round(event["seconds"], 3),
                      "rtf": round(event["rtf"], 3),
                      "pcm": base64.b64encode(pcm.tobytes()).decode()})
        except (BrokenPipeError, ConnectionResetError):
            # Navigated away, or Stop was pressed. Closing the generator
            # releases the engine lock; there is nothing else to undo.
            pass
        except Exception as exc:                              # noqa: BLE001
            with contextlib.suppress(OSError):
                line({"type": "error", "message": str(exc)})
        finally:
            stream.close()

    def send_web(self, name, content_type):
        try:
            with open(WEB / name, "rb") as handle:
                data = handle.read()
        except OSError:
            return self.fail(404, f"{name} is missing")
        self.reply(200, data, content_type, Cache_Control="no-store")


def _name_from(path):
    """
    The voice name out of /api/voices/<name>[/something].

    Unquoted, because a name is allowed spaces and punctuation — "Me, reading"
    arrives as "Me%2C%20reading", and comparing that against a directory called
    "Me, reading" fails every time. Names with a space were simply unreachable:
    404 on the sample, on rename and on delete.
    """
    parts = [p for p in path.split("/") if p]
    return urllib.parse.unquote(parts[2]) if len(parts) > 2 else ""


def _voice_route(path, action=None):
    """Match a complete route, so DELETE /name/sample.wav cannot delete name."""
    parts = path.split("/")
    expected = 5 if action else 4
    if (len(parts) != expected or parts[:3] != ["", "api", "voices"]
            or not parts[3] or (action and parts[4] != action)):
        return None
    return urllib.parse.unquote(parts[3])


def _string(payload, key):
    value = payload.get(key, "")
    if not isinstance(value, str):
        raise RequestError(f"{key} must be a string")
    return value


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
        with ThreadingHTTPServer((args.host, args.port), Handler) as server:
            server.serve_forever()
    except KeyboardInterrupt:
        print()
    finally:
        Handler.engine.close()


if __name__ == "__main__":
    main()
