#!/usr/bin/env bash
# One-line installer: builds editxr from source and copies it onto your PATH.
#   curl -fsSL https://raw.githubusercontent.com/pixdeo/editxr/main/install.sh | bash
#
# Override the destination with PREFIX, e.g. PREFIX="$HOME/.local/bin" ... | bash
set -euo pipefail

PREFIX="${PREFIX:-/usr/local/bin}"
REPO="https://github.com/pixdeo/editxr.git"

command -v swift >/dev/null 2>&1 || {
    echo "error: 'swift' not found. Install Xcode or the Command Line Tools (xcode-select --install)." >&2
    exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> Cloning editxr"
git clone --depth 1 "$REPO" "$tmp"

echo "==> Building (release)"
( cd "$tmp" && swift build -c release )

mkdir -p "$PREFIX"
install -m 0755 "$tmp/.build/release/editxr" "$PREFIX/editxr"
echo "==> Installed editxr to $PREFIX/editxr"
"$PREFIX/editxr" --version
