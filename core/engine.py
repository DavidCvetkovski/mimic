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
import math
import os
import shutil
import tempfile
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
CACHE_VERSION = "4"
MAX_TEXT_CHARACTERS = 10_000
MAX_VOICE_CHARACTERS = 64
MAX_AUDIO_BYTES = 50 * 1024 * 1024

# The reference implementation wants every model file in one flat directory;
# a Hugging Face snapshot puts the voice-registration encoder in a subfolder.
REGISTRATION_FILES = ("codec_encoder_fp16.onnx", "codec_encoder_fp16.onnx.data",
                      "registration_manifest.json")


class ModelMissing(RuntimeError):
    """Raised when the weights have not been downloaded yet."""


def validate_voice_name(name: str) -> str:
    """Names are portable labels, never filesystem paths."""
    if (not isinstance(name, str) or not name.strip()
            or name != name.strip() or len(name) > MAX_VOICE_CHARACTERS
            or name in {".", ".."} or "/" in name or "\\" in name
            or any(ord(char) < 32 or ord(char) == 127 for char in name)
            or len(name.encode("utf-8")) > 255):
        raise ValueError(
            "voice name must be 1–64 characters without paths or control characters"
        )
    return name


def _voice_path(name: str) -> Path:
    path = VOICES_DIR / validate_voice_name(name)
    if path.is_symlink():
        raise ValueError("a voice cannot be a symbolic link")
    return path


def _atomic_write(path: Path, data: bytes):
    """Readers see the old file or the complete new file, never half a WAV."""
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=path.parent, prefix=".mimic-", delete=False
        ) as handle:
            temporary = Path(handle.name)
            handle.write(data)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


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
        self._stop = threading.Event()
        self._voice_versions: dict[str, int] = {}
        self._cache_generation = 0
        for directory in (VOICES_DIR, CACHE_DIR):
            directory.mkdir(parents=True, exist_ok=True)
        _discard_stale_cache()
        self._reaper_thread = None
        if idle_unload:
            self._reaper_thread = threading.Thread(target=self._reaper, daemon=True)
            self._reaper_thread.start()

    # ---- the model itself ----

    @property
    def loaded(self) -> bool:
        return self._runtime is not None

    def _reaper(self):
        while not self._stop.wait(30):
            with self._lock:
                if (self._runtime is not None and self.idle_unload
                        and time.monotonic() - self._last_used > self.idle_unload):
                    self._runtime = None

    def unload(self):
        """Release model memory once the current sentence has finished."""
        with self._lock:
            self._runtime = None

    def close(self):
        self._stop.set()
        if self._reaper_thread is not None:
            self._reaper_thread.join(timeout=1)
        self.unload()

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
        with self._lock:
            return self._voices()

    def _voices(self) -> list[dict]:
        found = []
        for directory in sorted(VOICES_DIR.iterdir()) if VOICES_DIR.is_dir() else []:
            # meta.json is the vendored runtime's own layout; matching it means
            # a voice registered by either side is readable by both.
            meta = directory / "meta.json"
            if directory.is_symlink() or meta.is_symlink() or not meta.is_file():
                continue
            try:
                with open(meta) as handle:
                    entry = json.load(handle)
            except (OSError, ValueError):
                continue
            if not isinstance(entry, dict):
                continue
            entry["name"] = directory.name
            sample = directory / "reference.wav"
            entry["has_sample"] = sample.is_file() and not sample.is_symlink()
            found.append(entry)
        return sorted(found, key=lambda v: str(v.get("created_at") or ""), reverse=True)

    def register(self, name: str, wav_bytes: bytes, transcript: str,
                 overwrite: bool = False) -> dict:
        """
        Turn a recording into a reusable voice profile.

        The encoder is a second gigabyte of weights and is only needed here, so
        it is loaded for this call and dropped again rather than kept resident
        for something you do once per voice.
        """
        directory = _voice_path(name)
        if not isinstance(transcript, str) or not transcript.strip():
            raise ValueError("the recording transcript is required")
        if len(transcript) > MAX_TEXT_CHARACTERS:
            raise ValueError(f"transcript must be at most {MAX_TEXT_CHARACTERS:,} characters")
        if not isinstance(wav_bytes, bytes) or not 0 < len(wav_bytes) <= MAX_AUDIO_BYTES:
            raise ValueError("audio file must be between 1 byte and 50 MiB")
        if not isinstance(overwrite, bool):
            raise ValueError("overwrite must be true or false")
        with self._lock:
            if directory.exists() and not overwrite:
                raise FileExistsError(f"voice already exists: {name}")
            if not model_ready():
                raise ModelMissing("the model has not been downloaded yet")
            from .vendor.arktts.registration import VoiceRegistration

            self._runtime = None                # free the online sessions first
            registration = VoiceRegistration(
                MODEL_DIR, VOICES_DIR, self.manifest["model_fingerprint"])
            state = registration.status()
            if not state["available"]:
                raise RuntimeError(state["reason"])
            result = registration.register(
                data=wav_bytes, filename="reference.wav",
                text=transcript, name=name, overwrite=overwrite)
            self._voice_versions[name] = self._voice_versions.get(name, 0) + 1
            self._forget_cached(name)
            # Keep the original recording while the library is still locked.
            _atomic_write(directory / "reference.wav", wav_bytes)
        return result

    def rename(self, old: str, new: str) -> bool:
        try:
            source, target = _voice_path(old), _voice_path(new)
        except ValueError:
            return False
        with self._lock:
            if not source.is_dir() or (source / "meta.json").is_symlink():
                return False
            if old == new:
                return True
            if target.exists():
                return False
            try:
                metadata = json.loads((source / "meta.json").read_text())
                if not isinstance(metadata, dict):
                    return False
                metadata["name"] = new
                source.rename(target)
                try:
                    _atomic_write(target / "meta.json", json.dumps(metadata).encode())
                except OSError:
                    target.rename(source)
                    raise
            except (OSError, ValueError):
                return False
            for name in (old, new):
                self._voice_versions[name] = self._voice_versions.get(name, 0) + 1
                self._forget_cached(name)
            return True

    def delete(self, name: str) -> bool:
        try:
            directory = _voice_path(name)
        except ValueError:
            return False
        with self._lock:
            if not directory.is_dir():
                return False
            shutil.rmtree(directory)
            self._voice_versions[name] = self._voice_versions.get(name, 0) + 1
            self._forget_cached(name)
            return True

    def sample(self, name: str) -> bytes | None:
        """The original recording, for playing back in a voice picker."""
        try:
            with self._lock:
                path = _voice_path(name) / "reference.wav"
                if path.is_symlink():
                    return None
                return path.read_bytes()
        except (OSError, ValueError):
            return None

    # ---- speaking ----

    def _cache_path(self, text: str, voice: str, seed: int,
                    temperature: float = 0.7, top_p: float = 0.9,
                    top_k: int = 50, max_new_tokens: int = 1024) -> Path:
        settings = [CACHE_VERSION, voice, seed, text, temperature, top_p, top_k, max_new_tokens]
        digest = hashlib.sha256(json.dumps(settings, ensure_ascii=False).encode()).hexdigest()
        return CACHE_DIR / f"{self._cache_prefix(voice)}{digest[:24]}.wav"

    @staticmethod
    def _cache_prefix(voice: str) -> str:
        return hashlib.sha256(voice.encode()).hexdigest()[:16] + "-"

    def _forget_cached(self, voice: str):
        for path in CACHE_DIR.glob(f"{self._cache_prefix(voice)}*.wav"):
            path.unlink(missing_ok=True)

    def clear_cache(self):
        with self._lock:
            self._cache_generation += 1
            for path in CACHE_DIR.glob("*.wav"):
                path.unlink(missing_ok=True)

    def storage(self) -> dict:
        sizes = {}
        for label, directory in (
            ("model", MODEL_DIR),
            ("voices", VOICES_DIR),
            ("cache", CACHE_DIR),
        ):
            size = 0
            for path in directory.rglob("*") if directory.is_dir() else []:
                try:
                    if path.is_file() and (label == "model" or not path.is_symlink()):
                        size += path.stat().st_size
                except OSError:
                    continue
            sizes[label] = size
        sizes["total"] = sum(sizes.values())
        return sizes

    def validate_speech(self, text: str, voice: str, seed: int = 42) -> str:
        if not isinstance(text, str):
            raise ValueError("text must be a string")
        if len(text) > MAX_TEXT_CHARACTERS:
            raise ValueError(f"text must be at most {MAX_TEXT_CHARACTERS:,} characters")
        text = " ".join(text.split())
        if not text:
            raise ValueError("nothing to say")
        if isinstance(seed, bool) or not isinstance(seed, int) or not 0 <= seed <= 0xFFFFFFFF:
            raise ValueError("seed must be an integer between 0 and 4294967295")
        with self._lock:
            meta = _voice_path(voice) / "meta.json"
            if meta.is_symlink() or not meta.is_file():
                raise ValueError(f"no such voice: {voice}")
        return text

    @staticmethod
    def _read_cached(path: Path) -> bytes | None:
        try:
            if path.is_symlink():
                return None
            data = path.read_bytes()
            if _wav_seconds(data) > 0:
                os.utime(path, None)
                return data
            path.unlink(missing_ok=True)
        except OSError:
            pass
        return None

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
        # This method intentionally returns a generator instead of yielding:
        # validation runs now, before an HTTP handler commits a 200 response.
        text = self.validate_speech(text, voice, seed)
        for label, value, lower, upper in (("temperature", temperature, 0, 5),
                                            ("top_p", top_p, 0, 1)):
            if (isinstance(value, bool) or not isinstance(value, (int, float))
                    or not math.isfinite(value) or not lower < value <= upper):
                raise ValueError(f"{label} must be greater than {lower} and at most {upper}")
        for label, value, lower, upper in (("top_k", top_k, 0, 1024),
                                            ("max_new_tokens", max_new_tokens, 1, 4096)):
            if (
                isinstance(value, bool)
                or not isinstance(value, int)
                or not lower <= value <= upper
            ):
                raise ValueError(f"{label} must be an integer between {lower} and {upper}")
        cached = self._cache_path(text, voice, seed, temperature, top_p, top_k, max_new_tokens)
        with self._lock:
            data = self._read_cached(cached)
            if data is None and self._runtime is None and not model_ready():
                raise ModelMissing("the model has not been downloaded yet")
            version = self._voice_versions.get(voice, 0)
            cache_generation = self._cache_generation
        return self._speak_stream(text, voice, seed, temperature, top_p, top_k,
                                  max_new_tokens, cached, data, version, cache_generation)

    def _speak_stream(self, text, voice, seed, temperature, top_p, top_k,
                      max_new_tokens, cached, data, version, cache_generation):
        import numpy as np

        if data is not None:
            yield {"done": True, "cached": True, "wav": data,
                   "seconds": _wav_seconds(data), "rtf": 0.0}
            return

        parts = split_sentences(text)
        started = time.monotonic()
        pieces = []
        spoken = 0.0

        for index, part in enumerate(parts):
            with self._lock:
                if version != self._voice_versions.get(voice, 0):
                    raise ValueError("the voice changed during generation; please try again")
                runtime = self._ensure()
                self._last_used = time.monotonic()
                audio, _ = runtime.synthesize(
                    text=part, voice=voice, max_new_tokens=max_new_tokens,
                    temperature=temperature, top_p=top_p, top_k=top_k,
                    seed=(seed + index) & 0xFFFFFFFF)
                self._last_used = time.monotonic()

            chunk = np.asarray(audio, dtype=np.float32)
            # A breath between sentences, or they run together.
            if index < len(parts) - 1:
                chunk = np.concatenate(
                    [chunk, np.zeros(int(SAMPLE_RATE * 0.18), dtype=np.float32)])
            pieces.append(chunk)
            spoken += len(chunk) / SAMPLE_RATE
            elapsed = time.monotonic() - started

            yield {"done": False, "cached": False, "samples": chunk,
                   "index": index, "of": len(parts),
                   "seconds": spoken,
                   # How much slower than real time this is running. The caller
                   # needs it to know how far ahead to buffer.
                   "rtf": elapsed / max(spoken, 0.01)}

        audio = np.concatenate(pieces) if pieces else np.zeros(1, dtype=np.float32)
        data = to_wav(audio)
        with self._lock:
            if (version == self._voice_versions.get(voice, 0)
                    and cache_generation == self._cache_generation):
                # Caching is an optimisation; a full disk must not discard
                # speech that has already been made successfully.
                try:
                    _atomic_write(cached, data)
                    _prune_cache()
                except OSError:
                    pass
        yield {"done": True, "cached": False, "wav": data,
               "seconds": len(audio) / SAMPLE_RATE,
               "rtf": (time.monotonic() - started) / max(len(audio) / SAMPLE_RATE, 0.01)}

    def speak(self, text: str, voice: str, seed: int = 42, temperature: float = 0.7,
              top_p: float = 0.9, top_k: int = 50, max_new_tokens: int = 1024):
        """
        Synthesise one passage. Returns (wav_bytes, seconds, from_cache).

        Deterministic for a given seed, which is what makes caching honest —
        the same words in the same voice really are the same audio.
        """
        # Both APIs must produce the same passage and share honest cache hits.
        # A one-shot render could silently truncate long text at its token cap.
        for event in self.speak_stream(text, voice, seed, temperature, top_p,
                                       top_k, max_new_tokens):
            if event["done"]:
                return event["wav"], event["seconds"], event["cached"]


def _clause_break(sentence: str, limit: int, overshoot: int = 60) -> int:
    """
    Where to cut a sentence too long to say in one go.

    Anywhere is not the answer. The model reads the whole chunk to decide its
    prosody, so a cut in the middle of a clause restarts the intonation
    mid-phrase and the join is audible: "...or to take arms" and "against a sea
    of troubles" arrive as two half-read fragments rather than one sentence.
    Any space is what it used to pick.

    So it breaks where a speaker breathes. The last clause mark before the
    limit is best; failing that the first one just after it, because
    overshooting a little is cheaper than a seam in the middle of a phrase. A
    break very near the start is refused — it would leave a three-word fragment
    and the rest still oversized.
    """
    # Just after a clause mark that is actually followed by a space, so a
    # decimal point or a comma inside a number is not a place to breathe.
    breaks = [i + 1 for i, char in enumerate(sentence[:-1])
              if char in ",;:\u2014\u2013" and sentence[i + 1] == " "]

    earliest = max(24, limit // 3)
    before = [b for b in breaks if earliest <= b <= limit]
    if before:
        return before[-1]
    after = [b for b in breaks if limit < b <= limit + overshoot]
    if after:
        return after[0]

    # Nothing to breathe at: a word boundary inside the limit, and a hard cut
    # only if there is not even one of those.
    cut = sentence.rfind(" ", 0, limit)
    return cut if cut > 0 else limit


def split_sentences(text: str, limit: int = 110) -> list[str]:
    """
    Break a passage where a speaker would pause.

    Short enough that the first one is ready quickly, long enough that the model
    still has a phrase to work with — it uses the whole chunk for prosody, so
    splitting per clause makes the result sound clipped.
    """
    import re

    if not isinstance(limit, int) or limit < 1:
        raise ValueError("sentence limit must be a positive integer")

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
            cut = _clause_break(piece, limit)
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
            frames = handle.getnframes()
            expected = frames * handle.getnchannels() * handle.getsampwidth()
            if len(handle.readframes(frames)) != expected:
                return 0.0
            return frames / handle.getframerate()
    except (OSError, EOFError, wave.Error, ZeroDivisionError):
        return 0.0
