#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product MakarovPulse
bin=$(swift build -c release --show-bin-path)
app="dist/Makarov Pulse.app"
mkdir -p "$app/Contents/MacOS"
install -m 755 "$bin/MakarovPulse" "$app/Contents/MacOS/MakarovPulse"
install -m 644 Packaging/Info.plist "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
