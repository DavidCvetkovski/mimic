# Vendored from Audio8_TTS

These files are copied unmodified from the ONNX Runtime reference
implementation in [Audio8-AI/Audio8_TTS](https://github.com/Audio8-AI/Audio8_TTS),
under the Apache License 2.0 (see `LICENSE` alongside this file).

| | |
|---|---|
| Upstream | <https://github.com/Audio8-AI/Audio8_TTS> |
| Path | `onnx_runtime/arktts_runtime/` |
| Commit | `421f71559848572431bd6229af3e1a73f25986a7` |
| Vendored | 2026-08-23 |

## Files

| File | What it does |
|---|---|
| `runtime.py` | The two autoregressive branches, KV cache, sampling loop, codec decode |
| `prompt.py` | Turns text and a reference voice into model input tokens |
| `registration.py` | Runs the codec encoder to turn a recording into a voice profile |
| `voices.py` | Reads and writes voice profiles on disk |

## Why vendored rather than depended on

Upstream ships this as example code inside a research repository, not as a
published package — there is nothing on PyPI to depend on, and the layout
assumes you cloned the whole repo. Copying it in keeps Mimic installable and
pins the exact revision the engine was tested against.

## Changes

None. Mimic's own code wraps these files rather than editing them, so this
directory stays a clean copy and can be re-synced from upstream by replacing
it. Anything Mimic needs to do differently lives in `core/engine.py`.
