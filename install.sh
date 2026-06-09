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

bin="$tmp/.build/release/editxr"
# Build runs as the current user; only the copy into PREFIX may need root.
if mkdir -p "$PREFIX" 2>/dev/null && install -m 0755 "$bin" "$PREFIX/editxr" 2>/dev/null; then
    :
else
    echo "==> $PREFIX needs elevated permissions; using sudo for the copy"
    sudo mkdir -p "$PREFIX"
    sudo install -m 0755 "$bin" "$PREFIX/editxr"
fi
echo "==> Installed editxr to $PREFIX/editxr"
"$PREFIX/editxr" --version
