#!/usr/bin/env bash
# Build static, dependency-free Linux binaries (x86_64 + aarch64) with the
# Swift Static Linux SDK (musl) and package each as a tar.gz for a GitHub
# release.
#
# The binaries link musl statically, so a single artifact runs on any Linux
# distro (Ubuntu, Debian, Alpine, Fedora, …) with no Swift runtime installed.
# Both architectures cross-compile from one host, so this runs unchanged on a
# Linux CI runner or locally.
#
# Prerequisites (one-time):
#   - A swift.org toolchain. The Static Linux SDK requires it; Apple's Xcode /
#     Command Line Tools toolchain is not supported for this SDK. Install one
#     with swiftly (https://www.swift.org/install) and point $SWIFT at it.
#   - The matching Static Linux SDK. The toolchain and SDK versions must match:
#       swift sdk install \
#         https://download.swift.org/swift-6.3.2-release/static-sdk/swift-6.3.2-RELEASE/swift-6.3.2-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
#         --checksum 3fd798bef6f4408f1ea5a6f94ce4d4052830c4326ab85ebc04f983f01b3da407
#
# Usage:  scripts/release-linux.sh [version]   e.g. scripts/release-linux.sh v1.1.0
# Env:    SWIFT (swift binary to use; defaults to `swift` on PATH)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo dev)}"
SWIFT="${SWIFT:-swift}"
ARCHES=(x86_64 aarch64)

# Fail early with a helpful message if the musl SDK isn't installed.
if ! "$SWIFT" sdk list 2>/dev/null | grep -qiE 'static-linux|linux-musl'; then
    echo "error: the Static Linux SDK (musl) is not installed for this toolchain." >&2
    echo "       Install it with the 'swift sdk install …' command in this script's header" >&2
    echo "       (the version must match: $("$SWIFT" --version | head -1))." >&2
    exit 1
fi

mkdir -p dist
for arch in "${ARCHES[@]}"; do
    triple="${arch}-swift-linux-musl"
    scratch=".build-linux-${arch}"
    echo "==> Building static Linux binary (${arch}, ${VERSION})"
    # -Xlinker -s strips symbols at link time via lld, so it works for whichever
    # arch we're cross-compiling (a host `strip` only handles its native arch).
    "$SWIFT" build -c release --swift-sdk "$triple" --scratch-path "$scratch" -Xlinker -s

    bin="$("$SWIFT" build -c release --swift-sdk "$triple" --scratch-path "$scratch" --show-bin-path)/editxr"

    out="editxr-${VERSION}-linux-${arch}"
    stage="dist/stage-${arch}"
    rm -rf "$stage" && mkdir -p "$stage"
    cp "$bin" "$stage/editxr"
    ( cd "$stage" && tar -czf "../${out}.tar.gz" editxr )
    echo "    dist/${out}.tar.gz  sha256: $(shasum -a 256 "dist/${out}.tar.gz" | awk '{print $1}')"
done

echo ""
echo "==> Done. Linux artifacts in dist/:"
ls -1 dist/*.tar.gz
