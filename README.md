# editxr

A minimalist Markdown editor for the terminal, written in Swift. It renders
Markdown live as you type, and has an LLM-assisted editing flow: select a
section, describe a change, and review the edit as an inline diff before
applying it.

```
test.md — My document

# Title

This is a **test** with *markdown*.

▪ Item 1
▪ Item 2
```

## Features

- **Live Markdown rendering** — headings, bold/italic, lists, task lists,
  tables, blockquotes, code blocks, and YAML frontmatter, rendered in place
  while staying editable.
- **Themes** — `System`, `Clay`, `Mono`, and `Monokai`, each with an
  independent appearance mode (`Auto` / `Dark` / `Light`). Auto follows the
  terminal background.
- **AI section editing** — rewrite the selection (or the current block) with
  an LLM, shown as a red/green **inline diff** you accept (`y`) or reject
  (`n`). Prompt history is recallable with ↑/↓.
- **Multiple LLM providers** — LM Studio (local), OpenAI, OpenRouter, and an
  offline **Mock** provider for trying the flow without a backend.
- **Command palette** — `Ctrl+P` for commands and settings, with submenus
  for LLM configuration.
- Word wrap, line numbers, soft tables, undo/redo, and **per-file cursor
  memory** (reopen a file where you left off).

## Build & run

editxr is a Swift Package. On most machines:

```bash
swift build -c release
swift run editxr path/to/file.md
```

A `build.sh` wrapper is included for environments where the default Xcode SDK
fails to compile (it uses the Command Line Tools toolchain):

```bash
./build.sh                 # debug build
./build.sh run file.md     # run
./build.sh install         # release build + copy to /usr/local/bin/editxr
```

Requires macOS 12+ and a Swift 5.9+ toolchain.

## Keybindings

| Key | Action |
| --- | --- |
| `Ctrl+S` | Save |
| `Ctrl+Q` / `Ctrl+D` | Quit |
| `Ctrl+R` | Toggle rendered / raw view |
| `Ctrl+W` | Toggle word wrap |
| `Ctrl+L` | Toggle line numbers |
| `Ctrl+P` | Command palette / settings |
| `Ctrl+Space` | AI assist (edit the section) |
| `Ctrl+U` / `Ctrl+G` | Undo / Redo |
| `Ctrl+H` | Delete word backward |
| `Ctrl+/` | Toggle help bar |
| Arrows / Shift+Arrows | Move / select |
| `Ctrl+←/→` | Move by word |
| `Home` / `End` / `PgUp` / `PgDn` | Navigate |

**In an AI edit:** type an instruction and press `Enter`; `↑`/`↓` recall
previous prompts; `Esc` cancels. While reviewing the diff: `y` / `Tab` accept,
`n` / `Esc` reject.

## LLM configuration

Open the command palette (`Ctrl+P`) → **LLM settings** to pick a provider:

- **LM Studio** — talks to an OpenAI-compatible endpoint, by default
  `http://localhost:1234`.
- **OpenAI** — sign in via OAuth (set `OPENAI_OAUTH_CLIENT_ID` in your
  environment first).
- **OpenRouter** — set your API key and a model
  (e.g. `anthropic/claude-3.5-sonnet`).
- **Mock (offline)** — a deterministic local transform, handy for trying the
  edit/review UI with no network.

Settings (theme, appearance, provider, keys) persist to
`~/.config/editxr/config.json`. Per-file cursor positions are stored in
`~/.config/editxr/positions.json`.

## License

MIT © Pixdeo LTD. See [LICENSE](LICENSE).
