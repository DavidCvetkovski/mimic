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
        return data, len(audio) / SAMPLE_RATE, False


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
