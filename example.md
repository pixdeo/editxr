---
title: Welcome to editxr
author: you
---

# editxr

A minimalist Markdown editor for the terminal. Open this file with
`editxr example.md` to see how it renders.

This is a paragraph with **bold**, *italic*, and `inline code`. Long lines
soft-wrap to the window width when word wrap is on (toggle with Ctrl+W).

## Lists

- A bullet item
- Another one, with **emphasis**

### Tasks

- [ ] An open task
- [*] One in progress
- [x] A finished one

Place the cursor on a task and press Ctrl+T to cycle its state:
`[ ]` → `[*]` → `[x]` → `[ ]`.

---

A `---` on its own line renders as a horizontal rule.

## Table

| Feature        | Shortcut   |
| -------------- | ---------- |
| Command palette | Ctrl+P    |
| AI assist       | Ctrl+Space |
| Save            | Ctrl+S     |

## Code

```swift
func greet(_ name: String) -> String {
    "Hello, \(name)!"
}
```

> A blockquote, for good measure.

## Try the AI edit

Select a paragraph (or just place the cursor in one), press Ctrl+Space, type an
instruction like "make this more concise", and review the inline diff before
accepting with `y` or rejecting with `n`.
