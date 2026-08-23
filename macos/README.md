# Mimic for macOS

A native SwiftUI app over the same engine the web app uses.

```bash
./macos/build.sh
open macos/build/Mimic.app
```

Requires macOS 14 or newer and the Xcode command line tools. There is no Xcode
project — see below.

## What it does differently from the web app

- **Records natively.** `AVAudioEngine` taps the microphone directly, so there
  is no browser and no secure-context restriction. The level meter reads the
  samples as they arrive.
- **Manages the engine.** On launch it looks for a running engine and attaches
  to it; if there is none it starts `core/server.py` as a child process and
  waits for health. Quitting stops it again.
- **Feels like a Mac app.** ⌘↩ to speak, a save panel for the WAV, right-click a
  voice to play, rename or delete it.

## Why it does not bundle Python

Vendoring an interpreter, ONNX Runtime and a gigabyte of weights into the `.app`
would quadruple its size and freeze the engine at build time — and the engine is
the part most likely to change. Instead the app finds a checkout and runs it,
which also guarantees the web app and this one are never different versions.

It looks in, in order:

1. `defaults write dev.mimic.app MimicRoot /path/to/Mimic`
2. two directories above the `.app` (i.e. running from `macos/build/` in a checkout)
3. `~/Developer/Mimic`, then `~/Mimic`

and needs a `.venv` inside whichever it finds. If none matches, the app says so
rather than failing silently.

## Why there is no Xcode project

The app is five Swift files and a plist. A `.pbxproj` is tens of kilobytes of
generated XML that nobody can meaningfully review in a diff, and it would be the
largest file in the repository by some margin. `build.sh` calls `swiftc` and
assembles the bundle — about twenty lines, all of them readable.

The one part that is not obvious: the bundle is **ad-hoc code signed**. macOS
ties microphone permission to a signing identity, and an unsigned binary has
none — so without `codesign` the prompt reappears on every launch and then fails.

## Files

| | |
|---|---|
| `Sources/MimicApp.swift` | entry point, and finding the engine |
| `Sources/Engine.swift` | the child process and the HTTP client |
| `Sources/ContentView.swift` | the main window |
| `Sources/RecordView.swift` | the add-a-voice sheet |
| `Sources/Recorder.swift` | microphone capture to WAV |
