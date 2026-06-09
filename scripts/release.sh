#!/usr/bin/env bash
# Build a universal (arm64 + x86_64), Developer ID-signed and notarised editxr
# binary, zipped for a GitHub release.
#
# Prerequisites (one-time):
#   - A "Developer ID Application: Pixdeo LTD" certificate in your keychain.
#   - Notary credentials stored as a profile:
#       xcrun notarytool store-credentials pixdeo \
#         --apple-id you@pixdeo.com --team-id TEAMID --password <app-specific-pw>
#
# Usage:  scripts/release.sh [version]      e.g. scripts/release.sh v1.0.0
# Env:    SIGN_ID, NOTARY_PROFILE, DEVELOPER_DIR
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo dev)}"
SIGN_ID="${SIGN_ID:-Developer ID Application: Pixdeo LTD}"
NOTARY_PROFILE="${NOTARY_PROFILE:-pixdeo}"
# Match build.sh: the Command Line Tools toolchain builds cleanly here.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SWIFT="$DEVELOPER_DIR/usr/bin/swift"

echo "==> Building universal release ($VERSION)"
"$SWIFT" build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/editxr"
[ -f "$BIN" ] || BIN=".build/release/editxr"
lipo -info "$BIN" || true

echo "==> Signing as: $SIGN_ID"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$BIN"
codesign --verify --strict --verbose=2 "$BIN"

OUT="editxr-$VERSION-macos-universal"
rm -rf dist && mkdir -p dist/stage
cp "$BIN" dist/stage/editxr
( cd dist/stage && zip -q "../$OUT.zip" editxr )

echo "==> Notarising (this can take a minute)"
xcrun notarytool submit "dist/$OUT.zip" --keychain-profile "$NOTARY_PROFILE" --wait

echo ""
echo "==> Done: dist/$OUT.zip"
echo "    Note: a bare CLI binary can't be stapled; Gatekeeper verifies the"
echo "    notarisation online on first run (needs network once)."
echo "    sha256: $(shasum -a 256 "dist/$OUT.zip" | awk '{print $1}')"
