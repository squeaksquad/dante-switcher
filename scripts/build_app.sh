#!/bin/zsh
# Builds build/DanteSwitcher.app and signs it with the Developer ID (hardened runtime).
# Signed from the first build: macOS keys the local-network permission to the signature, and an
# ad-hoc build loses it on every rebuild (the heartbeat listeners then hear nothing, with no error).
# Universal (arm64 + x86_64). VERSION sets the version shown to users (default 0.1); the build
# number is the commit count, so every release build is higher than the last.
# Not notarized here: scripts/release.sh builds through this, then packages and notarizes.
# --install also copies it to /Applications, the only place Launch at Login is offered: a login
# item points at the app's path, and the copy in build/ is replaced by every build.
set -euo pipefail
cd "${0:A:h}/.."

IDENTITY="Developer ID Application: Bryan DiMaio (H674XZA5GP)"
APP=build/DanteSwitcher.app
VERSION="${VERSION:-0.1}"
BUILD="$(git rev-list --count HEAD)"
ARCHS=(--arch arm64 --arch x86_64)

swift build -c release --product DanteSwitcher "${ARCHS[@]}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release "${ARCHS[@]}" --show-bin-path)/DanteSwitcher" "$APP/Contents/MacOS/DanteSwitcher"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.bryandimaio.DanteSwitcher</string>
    <key>CFBundleName</key><string>Dante Switcher</string>
    <key>CFBundleExecutable</key><string>DanteSwitcher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Dante Switcher listens to the Dante network's heartbeats to show its sample rate.</string>
    <key>NSBonjourServices</key>
    <array><string>_netaudio-cmc._udp</string></array>
</dict>
</plist>
PLIST

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x DanteSwitcher || true
    rm -rf /Applications/DanteSwitcher.app
    ditto "$APP" /Applications/DanteSwitcher.app
    echo "Installed /Applications/DanteSwitcher.app"
fi
