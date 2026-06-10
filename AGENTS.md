# editxr agent guide

This repository is a Swift Package Manager (SPM) project for a
terminal-based Markdown editor. The codebase is small and mostly lives
under Sources/editxr.

If there are cursor or copilot rules, follow them first. None were found
in this repo.

## Build, run, test

Build (debug):
- swift build

Run (debug):
- swift run editxr path/to/file.md
- ./.build/debug/editxr path/to/file.md

Build (release):
- swift build -c release

Run (release):
- ./.build/release/editxr path/to/file.md

Tests:
- swift test
- Note: no test targets are currently present.

Single test (if/when tests exist):
- swift test --filter <TestCase>/<testMethod>
- Example: swift test --filter EditorStateTests/testUndo

Lint/format:
- No lint or formatter configured (no SwiftLint or SwiftFormat config).
- Do not introduce new tooling without asking.

## Repo layout

- Package.swift: SPM manifest (Swift 5.9, macOS 12+).
- Sources/editxr/main.swift: CLI entry point.
- Sources/editxr/App: editor app lifecycle and rendering.
- Sources/editxr/Models: editor state and data models.
- Sources/editxr/Services: network and OAuth integration.
- Sources/editxr/Views: TUI overlays and panels.
- Sources/editxr/Utils: key bindings, theming, markdown parsing.

## Releasing

- See RELEASING.md for the full process and caveats. In short: macOS is a manual
  signed/notarised local build (scripts/release.sh); the static Linux binaries
  (x86_64 + aarch64) are built in CI on tag (.github/workflows/release.yml via
  scripts/release-linux.sh). install.sh downloads the prebuilt for the platform
  and falls back to building from source.
- The Static Linux SDK version must match the Swift toolchain version exactly
  (currently Swift 6.3.2 / static-linux 0.1.0); bump them together.

## Configuration and runtime behavior

- User config file: ~/.config/editxr/config.json
- LLM provider defaults to LM Studio (http://localhost:1234).
- OpenAI OAuth is optional and driven by env vars.

## Memory policy (SimpleMem)

- Before responding, if user/project context is missing: query memory (search).
- After important decisions (naming, architecture, preferences): store a short summary (add).
- Do not store secrets, tokens, or sensitive data.

## Code style and conventions

### Imports

- Prefer the minimal set of imports per file.
- Standard pattern is `import Foundation` first.
- Keep imports at the very top of the file, no blank lines above.

### Formatting

- Indent with 4 spaces.
- Keep line length reasonable; wrap long parameter lists.
- One blank line between type definitions and major sections.
- No trailing whitespace.
- Use trailing commas only where already present (rare here).

### Types and structure

- Use `struct` for plain data (e.g., models, spans).
- Use `class` for stateful services and controllers.
- Prefer `final class` unless subclassing is required.
- Use `enum` for finite states and configuration options.
- Keep helper types `private` or file-scoped where possible.

### Naming

- Types: PascalCase (EditorState, LLMService).
- Members and functions: lowerCamelCase (toggleViewMode).
- Enum cases: lowerCamelCase (openaiOAuth, processing).
- Use descriptive, domain-specific names over abbreviations.

### Access control

- Default to `private` for helpers and internal state.
- Expose only what other modules need.
- Use `private(set)` for publicly readable but internally mutable state.

### Optionals and guards

- Prefer `guard` for early returns.
- Avoid force unwraps; use `if let` or `guard let`.
- Treat optional state explicitly (e.g., selectionRange).

### Error handling

- Use `Result` and `LocalizedError` for user-facing operations.
- Map network failures to typed errors (see LLMError, OAuthError).
- Avoid silent failures unless intentionally non-fatal.
- If you must ignore an error, add a brief reason.

### Concurrency and callbacks

- UI/state updates should occur on the main queue.
- Use `[weak self]` in escaping closures to avoid retain cycles.
- Avoid adding async/await unless used consistently across files.

### State management

- EditorState is the single source of truth for UI state.
- Keep view rendering pure: compute strings from state.
- Update config via Config.save() whenever persistent settings change.

### Rendering and terminal output

- ANSI escape sequences are hand-crafted in Theme and renderers.
- Preserve existing escape handling for width calculations.
- When updating render logic, keep cursor placement exact.

### Parsing and text editing

- Markdown parsing is minimal and inline; keep it simple and fast.
- For spans, keep raw vs content indexes consistent.
- Editing operations should preserve the trailing empty line.

### Networking

- OpenAI and LM Studio use OpenAI-compatible endpoints.
- Keep timeouts explicit (see LLMService).
- Use URLSession with completion handlers for now.

### Files and paths

- Use absolute paths only where required (config location).
- For file IO, prefer Foundation APIs with explicit encoding.

### Comments and docs

- Use `///` only for public-facing types or complex behavior.
- Avoid inline comments for obvious code.

## Adding new features

- Follow the existing layout: Models, Services, Views, Utils.
- Keep the TUI responsive; avoid blocking work on the main thread.
- Add configuration flags to Config with sensible defaults.

## Notes for agents

- No Cursor or Copilot rule files are present in the repo.
- The app is a single target executable; no test target yet.
- Keep changes minimal and consistent with the current style.
- Use english for git messages.
- Use english for code and comments.
