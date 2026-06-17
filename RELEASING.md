# Releasing editxr

Prebuilt binaries are attached to every GitHub release. There are two build
paths, by platform, and they meet at one set of asset names that `install.sh`
relies on.

| Platform | Built by | Where it runs | Asset |
| --- | --- | --- | --- |
| macOS (universal) | `scripts/release.sh` | manual, on a Mac | `editxr-<version>-macos-universal.zip` |
| Linux x86_64 | `scripts/release-linux.sh` | CI (`.github/workflows/release.yml`) | `editxr-<version>-linux-x86_64.tar.gz` |
| Linux aarch64 | `scripts/release-linux.sh` | CI | `editxr-<version>-linux-aarch64.tar.gz` |

## Procedure

1. Tag the release: `git tag vX.Y.Z`.
2. **macOS (manual, on a Mac):** `scripts/release.sh vX.Y.Z`. This builds the
   universal binary, signs and notarises it, and writes the zip to `dist/`.
   Create the GitHub release and upload that zip
   (`gh release create vX.Y.Z dist/editxr-vX.Y.Z-macos-universal.zip ...`).
3. **Linux (CI):** `git push origin vX.Y.Z`. The `release` workflow builds the
   two static tarballs and attaches them to a **draft** release for the tag. (You
   can also run it from the Actions tab via `workflow_dispatch`, passing the tag.)
4. **Publish:** upload the macOS zip to that draft release
   (`gh release upload vX.Y.Z dist/editxr-vX.Y.Z-macos-universal.zip`) and
   publish it (`gh release edit vX.Y.Z --draft=false`). The release is kept a
   draft until the macOS zip is present so it never becomes the "latest" that
   `install.sh` reads with the Linux binaries only.
5. **Homebrew tap:** run `scripts/bump-homebrew.sh vX.Y.Z`. It reads the sha256
   from the local `dist/` zip (or downloads the published asset), rewrites the
   formula in `pixdeo/homebrew-tap`, and commits + pushes it. Re-running is safe
   — it's a no-op once the formula is already at that version.

## Caveats to remember

### The Static Linux SDK version must match the toolchain version exactly
The Linux binaries are built with the **Static Linux SDK (musl)**, which is
pinned to one Swift toolchain version. Today that is **Swift 6.3.2** with
**static-linux 0.1.0**. When bumping the toolchain, update *all* of these
together or the SDK install fails:

- the container image in `.github/workflows/release.yml` (`swift:6.3.2`),
- the SDK URL **and** `--checksum` in that workflow,
- the example `swift sdk install …` command in the header of
  `scripts/release-linux.sh`.

Get the matching URL + checksum from the Static Linux SDK page on
<https://www.swift.org/install> for the toolchain version you're moving to.

### The Static Linux SDK needs a swift.org toolchain — not Apple's
Apple's Xcode / Command Line Tools toolchains are **not** supported by the
Static Linux SDK. That's why `scripts/release-linux.sh` does not run on a Mac
with the default toolchains, and why the Linux build lives in CI (the
`swift:6.3.2` image already has the right toolchain). To run it locally you'd
need swiftly + the matching swift.org toolchain + `swift sdk install …` first.

### macOS notarisation can't be stapled to a bare CLI binary
A standalone CLI binary can't be stapled, so Gatekeeper verifies the
notarisation **online on first run** (needs network once). `scripts/release.sh`
requires a `Developer ID Application` cert and a stored notary profile
(`NOTARY_PROFILE`, default `pixdeo`). It builds with the Command Line Tools
toolchain on purpose, to dodge the beta Xcode SDK on the build machine, and
makes the universal binary by building each arch and `lipo`-ing them (the
multi-arch `swift build` needs full Xcode's xcbuild, which we avoid).

### Asset names are a contract with `install.sh`
`install.sh` resolves the latest tag via the GitHub API and downloads the exact
asset names in the table above (macOS always gets the universal zip, regardless
of arch). If you rename a release asset, update `install.sh` to match, or the
one-line install silently falls back to building from source. Linux binaries are
statically linked against musl, so one file runs on any distro with no Swift
runtime; `FROM_SOURCE=1` forces a source build instead.
