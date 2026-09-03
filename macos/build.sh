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
# Some of MimicKit is compiled in rather than linked. This app talks HTTP to
# the Python engine and has no business pulling in ONNX Runtime — but these
# files carry none of it, and a palette or a set of passages that exists twice
# is one that drifts. The player is pure AVFoundation; Palette, Preset, Audio
# and Export are pure Foundation and AVFoundation.
KIT="$HERE/../MimicKit/Sources/MimicKit"
swiftc -O -parse-as-library -target "$TARGET" \
    -o "$APP/Contents/MacOS/Mimic" \
    "$HERE"/Sources/*.swift \
    "$KIT/StreamPlayer.swift" \
    "$KIT/Palette.swift" \
    "$KIT/Preset.swift" \
    "$KIT/Audio.swift" \
    "$KIT/Export.swift"

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
