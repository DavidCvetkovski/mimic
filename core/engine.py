"""
The engine: text and a voice in, audio out.

Everything model-shaped lives behind this one class, so the web app, the macOS
app and anything else added later talk to the same thing. The vendored Audio8
runtime does the actual inference; this owns the parts an application needs and
a research reference does not — where the model lives, what a voice library is,
not synthesising the same sentence twice, and letting go of a gigabyte of
weights when nobody has asked for anything in a while.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import threading
import time
from pathlib import Path

MODEL_REPO = "Audio8/Audio8-TTS-Preview-0.6B-ONNX-INT4"
SAMPLE_RATE = 44100

HOME = Path(os.environ.get("MIMIC_HOME", "~/.mimic")).expanduser()
MODEL_DIR = HOME / "model"
VOICES_DIR = HOME / "voices"
CACHE_DIR = HOME / "cache"

# Weights are ~1 GB resident. Hold them while someone is using the app and let
# them go afterwards, so an idle menu bar icon is not also a gigabyte of RAM.
IDLE_UNLOAD_SECONDS = 600

# How long a passage will take to say, from its length alone. Fitted against
# measured output: worst case about 1.3s out over a twenty-second line, which is
# accurate enough to size a progress bar and to decide when it is safe to start
# playing. Speech rate barely varies between voices — it is a property of the
# model, not the speaker.
SECONDS_PER_CHARACTER = 0.0647
SECONDS_BASE = 0.089

# Cached audio is small but unbounded, and a long-lived app would accumulate it
# forever. Trimmed oldest-first once it passes this.
CACHE_LIMIT_MB = 200
# Bumped whenever a change makes audio already on disk wrong. split_sentences
# shipped in a state where a passage mixing short and long sentences came out
# in the wrong order, and the cache kept the result — so fixing the splitter
# was not enough on its own.
CACHE_VERSION = "2"

# The reference implementation wants every model file in one flat directory;
# a Hugging Face snapshot puts the voice-registration encoder in a subfolder.
REGISTRATION_FILES = ("codec_encoder_fp16.onnx", "codec_encoder_fp16.onnx.data",
                      "registration_manifest.json")


class ModelMissing(RuntimeError):
    """Raised when the weights have not been downloaded yet."""


def model_ready() -> bool:
    return (MODEL_DIR / "runtime_manifest.json").is_file()


def download(progress=print) -> Path:
    """
    Fetch the weights and lay them out the way the runtime expects.

    Symlinked rather than copied: the Hugging Face cache already holds the real
    files, and a second copy of a gigabyte to satisfy a directory layout is a
    waste of somebody's disk.
    """
    from huggingface_hub import snapshot_download

    progress(f"downloading {MODEL_REPO} (~968 MiB, once)")
    snapshot = Path(snapshot_download(MODEL_REPO))

    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    for source in list(snapshot.iterdir()) + [snapshot / "registration" / name
                                              for name in REGISTRATION_FILES]:
        if not source.exists() or source.name in ("registration", ".cache"):
            continue
        link = MODEL_DIR / source.name
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(source.resolve())

    if not model_ready():
        raise ModelMissing(f"the download did not produce a usable model in {MODEL_DIR}")
    progress(f"model ready at {MODEL_DIR}")
    return MODEL_DIR


class Engine:
    """One model, loaded on demand, shared by every request."""

    def __init__(self, threads: int = 5, idle_unload: int = IDLE_UNLOAD_SECONDS):
        self.threads = threads
        self.idle_unload = idle_unload
        self._runtime = None
        self._last_used = 0.0
        self._lock = threading.Lock()          # generation is not reentrant
        for directory in (VOICES_DIR, CACHE_DIR):
            directory.mkdir(parents=True, exist_ok=True)
        _discard_stale_cache()
        threading.Thread(target=self._reaper, daemon=True).start()

    # ---- the model itself ----

    @property
    def loaded(self) -> bool:
        return self._runtime is not None

    def _reaper(self):
        while True:
            time.sleep(30)
            with self._lock:
                if (self._runtime is not None and self.idle_unload
                        and time.time() - self._last_used > self.idle_unload):
                    self._runtime = None

    def _ensure(self):
        if self._runtime is not None:
            return self._runtime
        if not model_ready():
            raise ModelMissing("the model has not been downloaded yet")
        from .vendor.arktts.runtime import ArkTtsRuntime
        self._runtime = ArkTtsRuntime(MODEL_DIR, VOICES_DIR, None, None, self.threads)
        return self._runtime

    @property
    def manifest(self) -> dict:
        with open(MODEL_DIR / "runtime_manifest.json") as handle:
            return json.load(handle)

    # ---- voices ----

    def voices(self) -> list[dict]:
        """Every registered voice, newest first."""
        found = []
        for directory in sorted(VOICES_DIR.iterdir()) if VOICES_DIR.is_dir() else []:
            # meta.json is the vendored runtime's own layout; matching it means
            # a voice registered by either side is readable by both.
            meta = directory / "meta.json"
            if not meta.is_file():
                continue
            try:
                with open(meta) as handle:
                    entry = json.load(handle)
            except (OSError, ValueError):
                continue
            entry["name"] = directory.name
            entry["has_sample"] = (directory / "reference.wav").is_file()
            found.append(entry)
        return sorted(found, key=lambda v: v.get("created_at", ""), reverse=True)

    def register(self, name: str, wav_bytes: bytes, transcript: str,
                 overwrite: bool = True) -> dict:
        """
        Turn a recording into a reusable voice profile.

        The encoder is a second gigabyte of weights and is only needed here, so
        it is loaded for this call and dropped again rather than kept resident
        for something you do once per voice.
        """
        from .vendor.arktts.registration import VoiceRegistration

        with self._lock:
            self._runtime = None                # free the online sessions first
            registration = VoiceRegistration(
                MODEL_DIR, VOICES_DIR, self.manifest["model_fingerprint"])
            state = registration.status()
            if not state["available"]:
                raise RuntimeError(state["reason"])
            result = registration.register(
                data=wav_bytes, filename="reference.wav",
                text=transcript, name=name, overwrite=overwrite)

        self._forget_cached(name)
        # Keep the recording itself so it can be played back and so a voice can
        # be rebuilt if the profile format ever changes.
        try:
            with open(VOICES_DIR / name / "reference.wav", "wb") as handle:
                handle.write(wav_bytes)
        except OSError:
            pass
        return result

    def rename(self, old: str, new: str) -> bool:
        source, target = VOICES_DIR / old, VOICES_DIR / new
        if not source.is_dir() or target.exists() or Path(new).name != new:
            return False
        source.rename(target)
        self._forget_cached(old)
        return True

    def delete(self, name: str) -> bool:
        directory = VOICES_DIR / name
        if not directory.is_dir() or Path(name).name != name:
            return False
        shutil.rmtree(directory, ignore_errors=True)
        self._forget_cached(name)
        return True

    def sample(self, name: str) -> bytes | None:
        """The original recording, for playing back in a voice picker."""
        path = VOICES_DIR / name / "reference.wav"
        try:
            with open(path, "rb") as handle:
                return handle.read()
        except OSError:
            return None

    # ---- speaking ----

    def _cache_path(self, text: str, voice: str, seed: int) -> Path:
        digest = hashlib.sha256(f"{voice}|{seed}|{text}".encode()).hexdigest()
        return CACHE_DIR / f"{voice}-{digest[:24]}.wav"

    def _forget_cached(self, voice: str):
        for path in CACHE_DIR.glob(f"{voice}-*.wav"):
            path.unlink(missing_ok=True)

    def estimate(self, text: str) -> float:
        """Roughly how many seconds of speech `text` will make."""
        length = len(" ".join(str(text).split()))
        return max(0.3, SECONDS_PER_CHARACTER * length + SECONDS_BASE)

    def speak_stream(self, text: str, voice: str, seed: int = 42,
                     temperature: float = 0.7, top_p: float = 0.9,
                     top_k: int = 50, max_new_tokens: int = 1024):
        """
        Render a sentence at a time, so listening can begin before the whole
        passage is made.

        The obvious way to stream is the runtime's own chunked decoder, which
        re-decodes a rolling window as frames arrive. Measured, that costs about
        twice the throughput — and the extra work eats exactly the head start it
        buys, so the audio finishes no sooner and sounds slightly worse. Whole
        sentences avoid it entirely: each one is a clean one-shot render, bit
        for bit what the non-streaming path produces.

        Yields one event per sentence, then a final summary. Deciding *when* to
        start playing is the caller's job — see the `rtf` field, which is what
        makes that decision possible.
        """
        import numpy as np

        text = " ".join(str(text).split())
        if not text:
            raise ValueError("nothing to say")
        if not (VOICES_DIR / voice / "meta.json").is_file():
            raise ValueError(f"no such voice: {voice}")

        cached = self._cache_path(text, voice, seed)
        if cached.is_file():
            data = cached.read_bytes()
            yield {"done": True, "cached": True, "wav": data,
                   "seconds": _wav_seconds(data), "rtf": 0.0}
            return

        parts = split_sentences(text)
        started = time.time()
        pieces = []
        spoken = 0.0

        for index, part in enumerate(parts):
            with self._lock:
                runtime = self._ensure()
                self._last_used = time.time()
                audio, _ = runtime.synthesize(
                    text=part, voice=voice, max_new_tokens=max_new_tokens,
                    temperature=temperature, top_p=top_p, top_k=top_k,
                    seed=seed + index)
                self._last_used = time.time()

            chunk = np.asarray(audio, dtype=np.float32)
            # A breath between sentences, or they run together.
            if index < len(parts) - 1:
                chunk = np.concatenate(
                    [chunk, np.zeros(int(SAMPLE_RATE * 0.18), dtype=np.float32)])
            pieces.append(chunk)
            spoken += len(chunk) / SAMPLE_RATE
            elapsed = time.time() - started

            yield {"done": False, "cached": False, "samples": chunk,
                   "index": index, "of": len(parts),
                   "seconds": spoken,
                   # How much slower than real time this is running. The caller
                   # needs it to know how far ahead to buffer.
                   "rtf": elapsed / max(spoken, 0.01)}

        audio = np.concatenate(pieces) if pieces else np.zeros(1, dtype=np.float32)
        data = to_wav(audio)
        cached.write_bytes(data)
        _prune_cache()
        yield {"done": True, "cached": False, "wav": data,
               "seconds": len(audio) / SAMPLE_RATE,
               "rtf": (time.time() - started) / max(len(audio) / SAMPLE_RATE, 0.01)}

    def speak(self, text: str, voice: str, seed: int = 42, temperature: float = 0.7,
              top_p: float = 0.9, top_k: int = 50, max_new_tokens: int = 1024):
        """
        Synthesise one passage. Returns (wav_bytes, seconds, from_cache).

        Deterministic for a given seed, which is what makes caching honest —
        the same words in the same voice really are the same audio.
        """
        text = " ".join(str(text).split())
        if not text:
            raise ValueError("nothing to say")
        if not (VOICES_DIR / voice / "meta.json").is_file():
            raise ValueError(f"no such voice: {voice}")

        cached = self._cache_path(text, voice, seed)
        if cached.is_file():
            data = cached.read_bytes()
            return data, _wav_seconds(data), True

        with self._lock:
            runtime = self._ensure()
            self._last_used = time.time()
            audio, _ = runtime.synthesize(
                text=text, voice=voice, max_new_tokens=max_new_tokens,
                temperature=temperature, top_p=top_p, top_k=top_k, seed=seed)
            self._last_used = time.time()

        data = to_wav(audio)
        cached.write_bytes(data)
        _prune_cache()
        return data, len(audio) / SAMPLE_RATE, False


def split_sentences(text: str, limit: int = 110) -> list[str]:
    """
    Break a passage where a speaker would pause.

    Short enough that the first one is ready quickly, long enough that the model
    still has a phrase to work with — it uses the whole chunk for prosody, so
    splitting per clause makes the result sound clipped.
    """
    import re

    parts, current = [], ""
    for piece in re.split(r"(?<=[.!?;:])\s+", " ".join(str(text).split())):
        while len(piece) > limit:                     # one very long clause
            # Whatever is already buffered comes first. Without this the
            # fragments of a long sentence were appended straight to the output
            # while an earlier, shorter sentence was still waiting in `current`
            # for company — so it was spoken after them, and the passage came
            # out in the wrong order.
            if current:
                parts.append(current)
                current = ""
            cut = piece.rfind(" ", 0, limit)
            if cut <= 0:
                cut = limit
            parts.append(piece[:cut].strip())
            piece = piece[cut:].strip()
        if current and len(current) + len(piece) + 1 > limit:
            parts.append(current)
            current = piece
        else:
            current = (current + " " + piece).strip()
    if current:
        parts.append(current)
    return [p for p in parts if p] or [text]


def _discard_stale_cache(version: str = CACHE_VERSION):
    """Throw the cache away when it may hold audio a later fix invalidated."""
    marker = CACHE_DIR / "VERSION"
    try:
        if marker.is_file() and marker.read_text().strip() == version:
            return
        for path in CACHE_DIR.glob("*.wav"):
            path.unlink(missing_ok=True)
        marker.write_text(version)
    except OSError:
        pass


def _prune_cache(limit_mb: int = CACHE_LIMIT_MB):
    """Drop the least recently used audio once the cache outgrows its budget."""
    try:
        files = [(p.stat().st_atime, p.stat().st_size, p) for p in CACHE_DIR.glob("*.wav")]
    except OSError:
        return
    total = sum(size for _, size, _ in files)
    budget = limit_mb * 1024 * 1024
    for _, size, path in sorted(files):
        if total <= budget:
            break
        try:
            path.unlink()
            total -= size
        except OSError:
            pass


# --------------------------------------------------------------------------
# WAV, without a dependency
# --------------------------------------------------------------------------

def to_wav(audio, sample_rate: int = SAMPLE_RATE) -> bytes:
    """float32 in [-1, 1] to 16-bit mono WAV bytes."""
    import io
    import wave

    import numpy as np

    pcm = (np.clip(np.asarray(audio, dtype=np.float32), -1.0, 1.0)
           * 32767.0).astype("<i2").tobytes()
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(sample_rate)
        handle.writeframes(pcm)
    return buffer.getvalue()


def _wav_seconds(data: bytes) -> float:
    import io
    import wave
    try:
        with wave.open(io.BytesIO(data), "rb") as handle:
            return handle.getnframes() / handle.getframerate()
    except (OSError, wave.Error):
        return 0.0
