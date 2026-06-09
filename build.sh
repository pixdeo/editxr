#!/usr/bin/env bash
# Build/run editxr using the CommandLineTools toolchain.
#
# Why: the default Xcode SDK on this machine (MacOSX26.2 beta) fails to compile
# Foundation/Darwin ("unknown type name 'uuid_string_t'"). CommandLineTools ships
# Swift 6.1.2 + a matching SDK that builds cleanly.
#
# Usage:
#   ./build.sh              # swift build (debug)
#   ./build.sh run FILE.md  # swift run editxr FILE.md
#   ./build.sh install      # release build + copy to /usr/local/bin/editxr
#   ./build.sh <args...>    # pass any args straight to swift
set -euo pipefail

# On this macOS box the CommandLineTools toolchain builds cleanly (the beta
# Xcode SDK doesn't); elsewhere (incl. Linux) just use swift from PATH.
if [ -x /Library/Developer/CommandLineTools/usr/bin/swift ]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    SWIFT=/Library/Developer/CommandLineTools/usr/bin/swift
else
    SWIFT="$(command -v swift)"
fi
PREFIX="${PREFIX:-/usr/local/bin}"

# Copy a file into PREFIX, escalating to sudo only if PREFIX isn't writable.
install_bin() {
    local src="$1" dest="$2"
    if install -m 0755 "$src" "$dest" 2>/dev/null; then return; fi
    echo "==> $dest needs elevated permissions; using sudo for the copy"
    sudo install -m 0755 "$src" "$dest"
}

if [ "$#" -eq 0 ]; then
    exec "$SWIFT" build
fi

# `./build.sh run FILE.md` -> swift run editxr FILE.md
if [ "$1" = "run" ]; then
    shift
    exec "$SWIFT" run editxr "$@"
fi

# `./build.sh install` -> release build, then copy the binary onto $PATH
if [ "$1" = "install" ]; then
    echo "Building release…"
    "$SWIFT" build -c release
    mkdir -p "$PREFIX" 2>/dev/null || sudo mkdir -p "$PREFIX"
    install_bin "$(pwd)/.build/release/editxr" "$PREFIX/editxr"
    echo "Installed editxr -> $PREFIX/editxr"
    exit 0
fi

exec "$SWIFT" "$@"
