# Mimic

**Type something. Hear it in your own voice.**

Mimic records you reading a paragraph once, then speaks anything you write in
that voice. The model, your recordings and the synthesis all stay on the
machine — nothing is uploaded, and it works with the network off.

[![tests](https://github.com/DavidCvetkovski/mimic/actions/workflows/tests.yml/badge.svg)](https://github.com/DavidCvetkovski/mimic/actions/workflows/tests.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![no pytorch](https://img.shields.io/badge/no-PyTorch-brightgreen.svg)](requirements.txt)

![Mimic in the browser: a text box, a voice picker, and a button that speaks it](docs/web.png)

## Try it

```bash
uv venv --python 3.13 .venv
VIRTUAL_ENV=.venv uv pip install -r requirements.txt
.venv/bin/python -m core.server --setup     # downloads ~968 MiB, once
.venv/bin/python -m core.server
```

Open <http://127.0.0.1:8455>, read the paragraph aloud, and type something.

## What it costs

Measured on an M5, with nothing else running:

| | |
|---|---|
| Download | 968 MiB, once |
| Memory | ~975 MB loaded, ~1.5 GB while speaking |
| Speed | **1.19x real time** — 16.7s of speech in 19.8s |
| Model load | 1.1s |
| Registering a voice | ~5s |

Saying the same thing twice is free: synthesis is deterministic for a given
seed, so the result is cached by voice and text.

## Why there is no PyTorch here

The obvious way to build this is `transformers` plus the PyTorch checkpoint.
Doing it through ONNX Runtime instead turned out better on every axis, which is
unusual enough to be worth writing down:

| | PyTorch, 0.1b | ONNX Runtime, 0.6B INT4 |
|---|---|---|
| Parameters | 0.1b | **0.6B — six times more** |
| Speed | 1.70x real time | **1.19x** |
| Memory | ~3 GB plus the runtime | **~1 GB** |
| Install | 2.5 GB of PyTorch + 1.6 GB of weights | **968 MiB, total** |
| Licence | Audio8 Community (revenue-capped) | **Apache 2.0** |
| Languages | 8 | 11 |

INT4 weight quantisation buys more on a CPU than the extra parameters cost.
The bigger model is the faster one, in less than half the memory, under a
licence that lets this repository exist.

## How it fits together

```
core/          the engine and its HTTP API — one implementation, every front end
  engine.py    model lifecycle, the voice library, caching
  server.py    the API below
  vendor/      Audio8's ONNX reference implementation, Apache 2.0, verbatim
web/           the browser app in the screenshot
macos/         a native shell over the same engine          (not built yet)
ios/           on-device, via ONNX Runtime Mobile           (not built yet)
tests/         Mimic's own logic — no model needed
```

Everything an application needs goes through one API, so a second front end is
a client rather than a fork:

| | |
|---|---|
| `GET /api/voices` | the library |
| `POST /api/voices` | register one — `{name, wav_hex, transcript}` |
| `POST /api/voices/<name>/rename` | `{name}` |
| `DELETE /api/voices/<name>` | |
| `GET /api/voices/<name>/sample.wav` | the original recording |
| `POST /api/speak` | `{text, voice, seed?}` → `audio/wav` |
| `GET /api/health` | |

State lives in `~/.mimic/` — set `MIMIC_HOME` to move it, which is how the
tests avoid touching a real install.

## Recording a good voice

Fifteen seconds is the sweet spot. Longer or noisier makes the clone worse
rather than better, and the transcript has to match what you actually said —
the model is told what the reference says, and a disagreement between the two
is the commonest cause of a poor result.

Recordings are captured as raw PCM through the Web Audio API and encoded to WAV
in the browser. `MediaRecorder` would hand back webm/opus or mp4/aac, and
decoding either server-side means depending on ffmpeg, which nothing here needs.

Microphone access requires a secure context, so recording works at
`127.0.0.1` and not over plain HTTP from another device.

## Tests

```bash
python3 -m unittest discover -s tests -t .
```

21 tests, no framework to install, and no model required — they cover the part
Mimic adds rather than the vendored runtime, which is upstream's to test.

## Not built yet

- **macOS app.** A native shell that manages the engine as a subprocess.
- **iOS, on device.** ONNX Runtime ships iOS builds and `CoreMLExecutionProvider`
  exists, and `runtime_manifest.json` fully specifies the architecture — so the
  work is porting the sampling loop to Swift rather than inventing anything.
  The tokenizer is the other half.
- **Text generation.** A small local LLM to write the text you then speak.

## Licence

Mimic is MIT — see [LICENSE](LICENSE).

It vendors Audio8's ONNX reference implementation under Apache 2.0, and
downloads Apache 2.0 model weights at first run. Neither the weights nor the
PyTorch base models (which carry a different, revenue-capped licence) are
distributed here. See [NOTICE](NOTICE).

**On cloning voices.** It should go without saying that this is for your own
voice, or one you have permission to use.
