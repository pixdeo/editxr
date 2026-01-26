# editxr

Un editor de Markdown en terminal (TUI) escrito en Swift. Minimalista, rapido, y con un modal de LLM para reescribir texto desde la seleccion o el parrafo actual.

## Uso

```bash
swift build
swift run editxr path/to/file.md
```

Release:

```bash
swift build -c release
./.build/release/editxr path/to/file.md
```

## Atajos (los mas usados)

- Ctrl+S guardar
- Ctrl+Q / Ctrl+D salir
- Ctrl+R toggle render/raw
- Flechas mover cursor
- Shift+Flechas seleccionar
- Ctrl+Left/Right saltar por palabras
- Ctrl+H borrar palabra hacia atras
- Ctrl+Space abrir modal LLM
- Ctrl+P abrir panel de comandos/settings
- Tab aceptar resultado del LLM
- Cmd+V (iTerm2 con bracketed paste) pega texto del sistema

## Config

Se guarda en `~/.config/editxr/config.json`.

## LLM

Habla con un endpoint OpenAI-compatible (por defecto LM Studio en `http://localhost:1234`).

Para OpenAI OAuth, setea `OPENAI_OAUTH_CLIENT_ID` en el ambiente y elegi "OpenAI (OAuth)" desde `Ctrl+P`.

## License

TBD
