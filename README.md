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

## Philosophy

editxr is for writing prose and notes in Markdown, in the terminal, without
ceremony. A few ideas guide it:

- **Render in place.** Markdown should look like Markdown *while you edit it* —
  headings, emphasis, lists, and tables styled inline — not a split preview
  pane. The text stays plain and editable; only the presentation is enriched.
- **Minimal by default.** A clean surface, a single accent colour, and quiet
  chrome. Settings exist but stay out of the way; the defaults are the point.
- **AI as a reviewable edit, not a chat.** The LLM rewrites a *section* and
  shows the result as an inline diff you accept or reject. No conversation
  thread, no copy-paste — just a proposed change you can see and undo.
- **Local-first and dependency-free.** Plain Swift, no runtime dependencies, a
  hand-editable JSON config, and an offline mock so the editing flow works with
  no backend at all. Bring your own model (local LM Studio, OpenAI, OpenRouter).
- **Fast and small.** It starts instantly and gets out of the way.

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
- **Export to HTML** — render the document to a clean, styled `.html` file and
  open it in the browser (`Ctrl+E`).
- **Syntax highlighting** — code files (JSON, Swift, JS/TS, C-family, …) open
  token-coloured instead of as Markdown.
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
| `Ctrl+E` | Export to HTML (and open it) |
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
