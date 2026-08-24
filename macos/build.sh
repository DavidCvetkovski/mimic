#!/usr/bin/env bash
# Builds Mimic.app.
#
# No Xcode project on purpose. The app is five Swift files and a plist, and a
# .pbxproj is forty kilobytes of generated XML that nobody can review in a diff.
# swiftc and a directory layout do the same job in a form you can read.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HERE/build/Mimic.app"
TARGET="${TARGET:-arm64-apple-macos14.0}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "compiling…"
# StreamPlayer is compiled in from MimicKit rather than linked or copied. This
# app talks HTTP to the Python engine and has no business pulling in ONNX
# Runtime, but the player is pure AVFoundation and there is no reason for two
# implementations of scheduling buffers back to back.
swiftc -O -parse-as-library -target "$TARGET" \
    -o "$APP/Contents/MacOS/Mimic" \
    "$HERE"/Sources/*.swift \
    "$HERE"/../MimicKit/Sources/MimicKit/StreamPlayer.swift

cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/Resources/Mimic.icns" "$APP/Contents/Resources/Mimic.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. Without one, macOS refuses to hand the app a microphone —
# the permission is remembered per signing identity, and an unsigned binary has
# none, so the prompt would reappear and then fail on every launch.
codesign --force --sign - --identifier dev.mimic.app \
    --options runtime "$APP" 2>/dev/null \
  || codesign --force --sign - --identifier dev.mimic.app "$APP"

echo "built $APP"
