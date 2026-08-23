# MimicKit — status

The engine, ported to Swift so it can run on a phone with no Python and no
server. **Not finished: it does not compile yet.** What follows is exactly
where it stands, because the interesting part of this port is what the platform
turned out not to support.

## Done

| | |
|---|---|
| `Manifest.swift` | the export's own description of its shape |
| `Sampler.swift` | top-k / top-p with the Gumbel-max trick, matching the reference |
| `VoiceStore.swift` | voice profiles, including a small `.npy` reader |
| `PromptBuilder.swift` | prompt construction, including the CJK line-break rule |
| `KVCache.swift` | flat float16 buffers, scatter-updated in place |
| `Runtime.swift` | both autoregressive branches and the generation loop |
| `Audio.swift` | WAV |

Dependencies resolve and the ONNX Runtime binaries download: ORT **1.24.2** via
Swift Package Manager, and swift-transformers 1.3.3 for the tokenizer.

## The blocker

**ONNX Runtime's Objective-C bindings cannot represent float16.** The whole of
`ORTTensorElementDataType` is:

```
Undefined, Float, Int8, UInt8, Int32, UInt32, Int64, UInt64, String
```

This model needs float16 for every KV cache tensor — 48 of them on the slow
branch alone — and for the hidden state handed between the two branches. So the
supported Swift path cannot run it at all.

The C API underneath *does* support float16
(`ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16`), and the xcframework ships the
headers, with `ios-arm64`, simulator and macOS slices, plus
`coreml_provider_factory.h`. But the framework has no `module.modulemap`, so
Swift cannot import it directly either.

**The way through** is a small Objective-C++ target inside this package that
includes `onnxruntime_c_api.h` and exposes a float16-capable session and tensor
interface to Swift. That is bounded, mapped work — not research — but it is
work: the shim has to cover session creation, running with mixed input types,
and reading typed outputs, since `ORTValue` cannot carry float16 either.

## Also outstanding

- `AutoTokenizer.from(tokenizerConfig:tokenizerData:)` wants a
  `tokenizer_config.json`; the model ships only `tokenizer.json`, so a minimal
  config has to be synthesised.
- An exclusivity violation in `KVCache.update` — `buffers` is accessed while
  being mutated. Needs a local copy or an `inout` slice.

## Why it builds for macOS too

Not an accident. A Swift reimplementation of an autoregressive loop is wrong in
ways only a comparison against the original will show, and a phone cannot be
stopped halfway through one. Building the same code for macOS means the port
can be run head to head with the Python engine — same prompt, same voice — and
the prompt tokens and the codec decode are both deterministic, so those can be
compared exactly. Only the sampling differs, and it differs on purpose:
Swift has no PCG64, so a seed does not reproduce NumPy's stream.
