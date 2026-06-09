# Demo recordings

GIFs shown in the top-level [`README.md`](../README.md). GitHub embeds GIFs
inline anywhere, so plain `![](demo/<name>.gif)` works without any release or
HTML tags.

## Expected files

| File | Shows |
| --- | --- |
| `render.gif` | Live Markdown rendering (headings, lists, tables, code) |
| `llm-edit.gif` | AI section editing with the inline diff (accept / reject) |
| `themes.gif` | Themes menu with live preview + dark / light |
| `find-export.gif` | Incremental find (`Ctrl+F` / `Ctrl+G`) and HTML export (`Ctrl+E`) |

Keep the same names so the README references resolve.

## Keep them small

GIFs live in git history forever, so favour short, tight clips:

- Aim for **< 5 MB** each (a few seconds, ~800–1000 px wide).
- Record a small terminal window, not a full screen.
- Trim dead time; loop a single clear action per clip.

Some ways to produce them:

- [`vhs`](https://github.com/charmbracelet/vhs) — script a terminal session to
  a GIF (most reproducible).
- QuickTime / screen capture to `.mov`, then convert with
  [`gifski`](https://github.com/ImageOptim/gifski):
  `ffmpeg -i clip.mov -vf fps=15 frames/%04d.png && gifski -o render.gif frames/*.png`

If a clip is too large to keep as a GIF, record it as MP4 and upload it as a
release/issue asset instead, then swap the README line for that URL.
