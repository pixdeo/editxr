#!/usr/bin/env bash
# Bump the Homebrew formula in pixdeo/homebrew-tap to a released version.
#
# Run this AFTER scripts/release.sh has built/notarised the macOS zip and the
# GitHub release is published (so the download URL resolves). It computes the
# sha256 from the local dist/ zip if present, otherwise downloads the published
# asset, rewrites Formula/editxr.rb, and commits + pushes the tap.
#
# Usage:  scripts/bump-homebrew.sh [version]    e.g. scripts/bump-homebrew.sh v1.3.0
# Env:    TAP_REPO (default pixdeo/homebrew-tap)
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo "")}"
[ -n "$TAG" ] || { echo "error: no version given and no tag found" >&2; exit 1; }
TAG="${TAG#v}"; TAG="v$TAG"          # normalise to a leading single 'v'
VERSION="${TAG#v}"                   # bare X.Y.Z for the formula's version field
TAP_REPO="${TAP_REPO:-pixdeo/homebrew-tap}"
ASSET="editxr-$TAG-macos-universal.zip"
URL="https://github.com/pixdeo/editxr/releases/download/$TAG/$ASSET"

# Prefer the freshly-built local zip; fall back to the published release asset.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
if [ -f "dist/$ASSET" ]; then
  ZIP="dist/$ASSET"
else
  echo "==> dist/$ASSET not found; downloading the published asset"
  gh release download "$TAG" --repo pixdeo/editxr --pattern "$ASSET" --dir "$tmp"
  ZIP="$tmp/$ASSET"
fi
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "==> $TAG  sha256=$SHA"

echo "==> Updating $TAP_REPO formula"
gh repo clone "$TAP_REPO" "$tmp/tap" -- --quiet
FORMULA="$tmp/tap/Formula/editxr.rb"
# Rewrite the three release-specific lines; everything else stays untouched.
sed -i '' \
  -e "s|^  url .*|  url \"$URL\"|" \
  -e "s|^  sha256 .*|  sha256 \"$SHA\"|" \
  -e "s|^  version .*|  version \"$VERSION\"|" \
  "$FORMULA"

if git -C "$tmp/tap" diff --quiet; then
  echo "==> Formula already at $VERSION; nothing to do"
  exit 0
fi
git -C "$tmp/tap" commit -aqm "editxr $VERSION"
git -C "$tmp/tap" push -q origin HEAD
echo "==> Done: $TAP_REPO bumped to $VERSION"
