"""Portable, versioned voice files shared with the iOS app. No model is required."""

import base64
import binascii
import io
import json
import shutil
import tempfile
import unicodedata
from pathlib import Path

import numpy as np

MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
_LIMITS = {
    "meta.json": 1024 * 1024,
    "codes.npy": 4 * 1024 * 1024,
    "reference.wav": 16 * 1024 * 1024,
}


def _name(value: str) -> str:
    if not isinstance(value, str):
        raise ValueError("A voice needs a name.")
    clean = value.strip()
    if (
        not clean
        or len(clean) > 60
        or clean.startswith(".")
        or any(c in clean for c in "/\\:")
        or any(unicodedata.category(c) == "Cc" for c in clean)
    ):
        raise ValueError("Use a name of 1–60 characters without slashes or control characters.")
    return clean


def _validate(files: dict[str, bytes], num_codebooks: int | None = None) -> dict:
    if not {"meta.json", "codes.npy"} <= files.keys() or files.keys() - _LIMITS.keys():
        raise ValueError("The voice file is missing required files or contains unknown files.")
    for filename, data in files.items():
        if not 0 < len(data) <= _LIMITS[filename]:
            raise ValueError(f"{filename} is empty or too large.")
    try:
        meta = json.loads(files["meta.json"])
    except (UnicodeError, ValueError) as error:
        raise ValueError("The voice metadata is damaged.") from error
    if (
        not isinstance(meta, dict)
        or not isinstance(meta.get("reference_text"), str)
        or not meta["reference_text"].strip()
    ):
        raise ValueError("The voice needs a reference transcript.")
    stream = io.BytesIO(files["codes.npy"])
    try:
        version = np.lib.format.read_magic(stream)
        if version == (1, 0):
            shape, fortran, dtype = np.lib.format.read_array_header_1_0(stream)
        elif version in ((2, 0), (3, 0)):
            shape, fortran, dtype = np.lib.format.read_array_header_2_0(stream)
        else:
            raise ValueError("Unsupported array version")
        if (
            len(shape) != 2
            or not 1 <= shape[0] <= 64
            or not 1 <= shape[1] <= 32768
            or fortran
            or dtype.str not in ("<u2", "<i2", "<i4", "<i8")
            or shape[0] * shape[1] * dtype.itemsize > len(stream.getbuffer()) - stream.tell()
            or (num_codebooks is not None and shape[0] != num_codebooks)
        ):
            raise ValueError("Invalid code matrix")
        codes = np.frombuffer(
            stream.getbuffer(), dtype=dtype, offset=stream.tell(), count=shape[0] * shape[1]
        )
        if np.any(codes < 0) or np.any(codes > 65535):
            raise ValueError("Voice codes are out of range")
    except (ValueError, TypeError, EOFError, OverflowError) as error:
        raise ValueError(
            "The voice codes are damaged or incompatible with this model."
        ) from error
    recording = files.get("reference.wav")
    if recording is not None and (
        len(recording) < 12 or recording[:4] != b"RIFF" or recording[8:12] != b"WAVE"
    ):
        raise ValueError("The reference recording is not a WAV file.")
    return meta


def export_voice(root: Path, name: str) -> bytes:
    """Export a library entry to a .mimicvoice JSON file; never follow symlinks."""
    clean = _name(name)
    directory = Path(root) / clean
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("That voice is not in the library.")
    files = {}
    for filename, limit in _LIMITS.items():
        path = directory / filename
        if path.is_symlink():
            raise ValueError("A voice file cannot link to another file.")
        if not path.exists() and filename == "reference.wav":
            continue
        with path.open("rb") as handle:
            files[filename] = handle.read(limit + 1)
    meta = _validate(files)
    meta["name"] = clean
    files["meta.json"] = json.dumps(meta, ensure_ascii=False).encode()
    result = json.dumps(
        {
            "format": "mimic.voice",
            "version": 1,
            "name": clean,
            "files": {
                key: base64.b64encode(value).decode("ascii") for key, value in files.items()
            },
        },
        ensure_ascii=False,
    ).encode()
    if len(result) > MAX_ARCHIVE_BYTES:
        raise ValueError("The voice file is too large to share.")
    return result


def import_voice(
    root: Path, data: bytes, name: str | None = None, num_codebooks: int | None = None
) -> str:
    """Validate and atomically install a .mimicvoice file, without replacing a voice."""
    if not 0 < len(data) <= MAX_ARCHIVE_BYTES:
        raise ValueError("Choose a voice file smaller than 32 MiB.")
    try:
        archive = json.loads(data)
    except (UnicodeError, ValueError) as error:
        raise ValueError("This is not a Mimic voice file.") from error
    if (
        not isinstance(archive, dict)
        or archive.get("format") != "mimic.voice"
        or type(archive.get("version")) is not int
        or archive["version"] != 1
        or not isinstance(archive.get("files"), dict)
    ):
        raise ValueError("This voice file uses an unsupported format or version.")
    original = _name(archive.get("name"))
    clean = _name(name) if name is not None else original
    files = {}
    try:
        for filename, encoded in archive["files"].items():
            if filename not in _LIMITS or not isinstance(encoded, str):
                raise ValueError("The voice file contains an unknown file.")
            if len(encoded) > ((_LIMITS[filename] + 2) // 3) * 4:
                raise ValueError(f"{filename} is too large.")
            files[filename] = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("The voice file contains damaged or oversized data.") from error
    meta = _validate(files, num_codebooks)
    meta["name"] = clean
    files["meta.json"] = json.dumps(meta, ensure_ascii=False).encode()
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    if any(entry.name.casefold() == clean.casefold() for entry in root.iterdir()):
        raise FileExistsError(f"A voice called {clean} already exists. Choose another name.")
    staging = Path(tempfile.mkdtemp(prefix=".voice-import-", dir=root))
    target = root / clean
    try:
        for filename, content in files.items():
            (staging / filename).write_bytes(content)
        # Reserve the destination exclusively. Renaming over our own empty folder
        # makes the entire profile visible together and cannot replace a voice.
        target.mkdir()
        try:
            staging.rename(target)
        except OSError:
            target.rmdir()
            raise
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return clean
