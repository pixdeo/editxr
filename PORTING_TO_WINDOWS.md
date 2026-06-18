# Porting editxr to Windows

editxr is a pure-Swift terminal text editor that currently targets macOS and
Linux. It leans heavily on POSIX terminal primitives (`termios`, `ioctl`,
signals, `/dev/tty`). This document tracks what blocks Windows, the chosen
approach, and the concrete work items.

**Scope of the first deliverable:** *core editing works* — the editor compiles
on Windows, enters raw mode, reports terminal size, reads input, and renders via
ANSI. Clipboard, theme auto-detection, and OAuth can start as graceful
fallbacks/stubs.

---

## Guiding principles

- **Don't break POSIX.** The macOS/Linux code paths stay byte-for-byte
  equivalent. The existing `termios`/`ioctl` logic is only *moved* behind a thin
  platform layer, never rewritten.
- **Modularize behind a single seam.** All OS branching lives in one place
  (`Sources/editxr/Platform/`) using `#if os(Windows)` / `#else`. Call sites stay
  platform-agnostic.
- **Keep ANSI as the lingua franca.** Windows 10+ console (conhost) and Windows
  Terminal support VT sequences via `ENABLE_VIRTUAL_TERMINAL_PROCESSING`
  (output) and `ENABLE_VIRTUAL_TERMINAL_INPUT` (input). With those enabled, the
  existing escape-sequence emission and the arrow/mouse parsers keep working
  unchanged.

---

## What blocks Windows today

| Area | Current (POSIX) | Location | Windows replacement |
|---|---|---|---|
| Raw input mode | `termios` + `tcgetattr`/`tcsetattr` | `EditorApp.swift:421-434`, `Theme.swift:34-40` | `GetConsoleMode`/`SetConsoleMode` with `ENABLE_VIRTUAL_TERMINAL_INPUT`, clearing `ENABLE_ECHO_INPUT`/`ENABLE_LINE_INPUT`/`ENABLE_PROCESSED_INPUT` |
| Terminal size | `ioctl(TIOCGWINSZ)` | `EditorApp.swift:840-846` | `GetConsoleScreenBufferInfo` → `srWindow` rect |
| stdin reading | `DispatchSource.makeReadSource(fileDescriptor:)` | `EditorApp.swift:288-293` | Background thread blocking on the console input handle, dispatching bytes to `.main` |
| Resize events | `SIGWINCH` signal source | `EditorApp.swift:298-302` | No such signal — poll terminal size (timer or per-render check) |
| Interrupt handling | `signal(SIGINT/SIGTSTP, SIG_IGN)` | `EditorApp.swift:295-296` | `SetConsoleCtrlHandler` (or rely on raw mode swallowing Ctrl-C) |
| VT output enablement | implicit (terminal already in VT) | — | `SetConsoleMode` with `ENABLE_VIRTUAL_TERMINAL_PROCESSING` + `DISABLE_NEWLINE_AUTO_RETURN` |
| Theme detection | reads `/dev/tty` + `poll()` for OSC 11 reply | `Theme.swift:28-50` | No `/dev/tty`; skip the query, fall back to `COLORFGBG`/default dark |
| Clipboard | `pbcopy`/`xclip`/`wl-copy`; PATH split on `:` | `SystemClipboard.swift` | `clip.exe` (write) / `powershell Get-Clipboard` (read); PATH split on `;` |
| Open browser (OAuth) | `/usr/bin/open` | `OpenAIOAuth.swift:119` | Already gated out — see below |

### Already handled

- **OAuth / OpenAI sign-in** is wrapped in
  `#if canImport(CryptoKit) && canImport(Network)`. Neither imports on Windows,
  so it compiles to the existing stub ("not available on this platform"). No work
  needed for the core deliverable.
- **`Package.swift`** declares `platforms: [.macOS(.v12)]`. That only sets Apple
  minimum versions; it does **not** restrict SwiftPM from building on Windows. No
  change required.

---

## Design: the platform seam

New file `Sources/editxr/Platform/PlatformTerminal.swift` exposes a small,
platform-agnostic surface. Two implementations behind `#if os(Windows)` / `#else`:

```
enableRawMode()          // input: no echo/line/signal; output: VT processing on
disableRawMode()         // restore the saved console/termios state
terminalSize() -> (width: Int, height: Int)
startInputLoop(_ onBytes: @escaping (Data) -> Void)   // dispatches to .main
startResizeWatch(_ onResize: @escaping () -> Void)     // SIGWINCH vs polling
```

- **POSIX backend** wraps the *existing* code verbatim: `termios` raw mode,
  `ioctl(TIOCGWINSZ)`, `DispatchSource` over `STDIN_FILENO`, `SIGWINCH` source.
- **Windows backend** uses `import WinSDK`: `GetStdHandle`, `GetConsoleMode`,
  `SetConsoleMode`, `GetConsoleScreenBufferInfo`, and a reader thread over the
  input handle. Resize is detected by polling `terminalSize()`.

Call sites in `EditorApp.swift` switch to these calls and stop touching POSIX
symbols directly.

---

## Work items (core: editing works)

- [x] Add `Sources/editxr/Platform/PlatformTerminal.swift` with POSIX + Windows
      backends (raw mode, size, input loop, resize watch).
- [x] Route `EditorApp.swift` `setInputMode`/`resetInputMode`/`getTerminalSize`
      and the `start()` input/resize setup through the platform layer.
- [x] Guard `Theme.swift` terminal-background query with `#if os(Windows)`;
      fall back to `COLORFGBG`/dark on Windows.
- [ ] Fix `SystemClipboard.swift` PATH separator per-OS and add `clip.exe` /
      `Get-Clipboard` tools (cheap win; otherwise the in-memory buffer is the
      backstop). *Not a compile blocker — the Windows build is already green
      without it.*
- [x] Confirm the build is unchanged — the Linux (POSIX) CI build stays green;
      the POSIX code is moved byte-for-byte behind the seam. (Local `swift build`
      on the dev Mac is currently blocked by an unrelated SDK/toolchain issue —
      `could not build Objective-C module 'Darwin'` — so CI is the source of
      truth for both paths.)

### Out of scope for now

- Mouse reporting parity on legacy conhost (works on Windows Terminal).
- OAuth browser flow on Windows (gated out; revisit if CryptoKit/Network land or
  a swift-crypto path is added).
- Installer / packaging / code signing for Windows.

---

## Verification

The Windows-specific code cannot be compiled or run from the macOS dev machine.
Two options:

1. **GitHub Actions `windows-latest` job** (recommended for a compile signal):
   set up the Swift toolchain and run `swift build`. Fast, zero local setup,
   catches Windows compile errors automatically.
2. **Local Windows VM** (needed to exercise the UX by hand): on Apple Silicon
   this means Windows 11 ARM (Parallels/UTM/VMware) plus the Swift for Windows
   toolchain, which pulls in the Windows SDK + Visual Studio Build Tools (several
   GB, ~1–2 h setup).

Each change is verified on macOS here (`swift build`) to guarantee the POSIX path
stays intact; the Windows path is verified later via CI or the VM.

---

## Status

**Core compile deliverable done.** The platform seam
(`Sources/editxr/Platform/PlatformTerminal.swift`) is in place and editxr now
compiles on Windows x86_64 (`windows-latest` CI, `.github/workflows/windows.yml`)
and still on Linux (the POSIX path is unchanged). A Windows 11 ARM QEMU VM exists
on the dev machine for the remaining hands-on UX pass (raw mode, rendering, resize
by hand). Runtime not yet exercised on Windows.

Remaining: SystemClipboard per-OS PATH/tools, and on-device UX verification.
