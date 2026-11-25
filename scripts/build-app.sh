#!/bin/sh
# Builds dist/Makarov Pulse.app.
#   PULSE_UNIVERSAL=1        one binary for arm64 and x86_64
#   PULSE_SIGN_IDENTITY=...  a Developer ID Application identity; default is ad-hoc signing
set -eu
cd "$(dirname "$0")/.."

set -- -c release --product MakarovPulse
if [ "${PULSE_UNIVERSAL:-0}" = 1 ]; then
    set -- "$@" --arch arm64 --arch x86_64
fi
swift build "$@"
bin=$(swift build "$@" --show-bin-path)

app="dist/Makarov Pulse.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$bin/MakarovPulse" "$app/Contents/MacOS/MakarovPulse"
install -m 644 Packaging/Info.plist "$app/Contents/Info.plist"
install -m 644 Sources/MakarovPulse/Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
plutil -lint "$app/Contents/Info.plist"

identity=${PULSE_SIGN_IDENTITY:--}
if [ "$identity" = - ]; then
    codesign --force --sign - "$app"
else
    # Distribution signing. Notarize and staple afterwards.
    codesign --force --timestamp --options runtime --sign "$identity" "$app"
fi
codesign --verify --strict "$app"
touch "$app"
lipo -archs "$app/Contents/MacOS/MakarovPulse"
printf '%s\n' "$app"
