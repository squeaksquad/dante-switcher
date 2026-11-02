#!/bin/zsh
# Builds a signed, notarized and stapled installer: build/DanteSwitcher-<version>.pkg.
#   scripts/release.sh 0.2.0            build, sign, notarize, staple
#   scripts/release.sh 0.2.0 --publish  then tag v0.2.0 and create a draft GitHub release with the pkg
# The pkg installs into /Applications (not relocatable: the login item and the local network grant
# follow that path), quits a running copy first and opens the new one after.
# Notarizes with the `vibetronics` notarytool keychain profile (shared with Vibetron; same team account).
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:?usage: scripts/release.sh <version> [--publish]}"
TEAM_ID="H674XZA5GP"
INSTALLER_ID="Developer ID Installer: Bryan DiMaio ($TEAM_ID)"
NOTARY_PROFILE="${NOTARY_PROFILE:-vibetronics}"
APP=build/DanteSwitcher.app
PKG="build/DanteSwitcher-$VERSION.pkg"

[[ -z "$(git status --porcelain)" ]] || { echo "Uncommitted changes: commit first, so the release matches a commit."; exit 1; }
swift test

echo "=== Build and sign the app ==="
VERSION="$VERSION" scripts/build_app.sh

echo "=== Package ==="
STAGE=build/pkgroot
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/DanteSwitcher.app"
pkgbuild --analyze --root "$STAGE" build/component.plist
plutil -replace 0.BundleIsRelocatable -bool NO build/component.plist
pkgbuild --root "$STAGE" --component-plist build/component.plist \
    --identifier com.bryandimaio.DanteSwitcher.pkg --version "$VERSION" \
    --install-location /Applications --scripts scripts/pkg \
    --sign "$INSTALLER_ID" --timestamp "$PKG"
rm -rf "$STAGE" build/component.plist

echo "=== Notarize ==="
xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json | tee build/notary.json
STATUS=$(plutil -extract status raw build/notary.json)
if [[ "$STATUS" != "Accepted" ]]; then
    echo "Notarization: $STATUS"
    xcrun notarytool log "$(plutil -extract id raw build/notary.json)" --keychain-profile "$NOTARY_PROFILE"
    exit 1
fi

echo "=== Staple and check ==="
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"
spctl --assess --type install --verbose=2 "$PKG"
shasum -a 256 "$PKG"
echo "Built $PKG"

if [[ "${2:-}" == "--publish" ]]; then
    git tag -a "v$VERSION" -m "Dante Switcher $VERSION"
    git push origin "v$VERSION"
    gh release create "v$VERSION" "$PKG" --draft --title "Dante Switcher $VERSION" --generate-notes
    echo "Draft release created; review and publish it on GitHub."
fi
