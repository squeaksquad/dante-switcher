#!/bin/zsh
# Builds build/DanteSwitcher.app and signs it with the Developer ID (hardened runtime).
# Signed from the first build: macOS keys the local-network permission to the signature, and an
# ad-hoc build loses it on every rebuild (the heartbeat listeners then hear nothing, with no error).
# Not notarized yet (Phase 4).
set -euo pipefail
cd "${0:A:h}/.."

IDENTITY="Developer ID Application: Bryan DiMaio (H674XZA5GP)"
APP=build/DanteSwitcher.app

swift build -c release --product DanteSwitcher
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/DanteSwitcher" "$APP/Contents/MacOS/DanteSwitcher"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.bryandimaio.DanteSwitcher</string>
    <key>CFBundleName</key><string>Dante Switcher</string>
    <key>CFBundleExecutable</key><string>DanteSwitcher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
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
