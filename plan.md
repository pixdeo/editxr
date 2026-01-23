# EditXR - Plan de Implementación

> Editor TUI ultra minimalista para Markdown, inspirado en iA Writer.
> Escrito en Swift usando SwiftTUI.

## Atajos de Teclado

| Atajo | Acción |
|-------|--------|
| `ctrl+s` | Guardar archivo |
| `ctrl+x` | Salir |
| `ctrl+r` | Toggle modo (plano ↔ renderizado) |
| `ctrl+b` | Toggle status bar |

> **Nota**: Las terminales no soportan `cmd+`, solo `ctrl+` genera códigos ASCII capturables.

## Arquitectura

```
editxr/
├── Package.swift
├── Sources/
│   └── editxr/
│       ├── main.swift                 # Entry point
│       ├── App/
│       │   └── EditorApp.swift        # Application root
│       ├── Views/
│       │   ├── EditorView.swift       # Vista principal
│       │   ├── TextEditorView.swift   # Editor de texto custom
│       │   ├── StatusBar.swift        # Barra inferior
│       │   └── MarkdownPreview.swift  # Vista renderizada MD
│       ├── Models/
│       │   ├── Document.swift         # Modelo del documento
│       │   └── EditorState.swift      # Estado global
│       ├── Services/
│       │   ├── FileService.swift      # Lectura/escritura archivos
│       │   └── MarkdownRenderer.swift # Parseo y render MD
│       └── Utils/
│           └── KeyBindings.swift      # Códigos ASCII para ctrl+
```

## Dependencias

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/rensbreur/SwiftTUI", from: "0.1.0"),
    .package(url: "https://github.com/apple/swift-markdown", from: "0.2.0"),
]
```

## Fases de Implementación

### Fase 1: Editor Básico
- [ ] Estructura del proyecto con SPM
- [ ] TextEditorView custom (SwiftTUI no tiene editor multilínea)
- [ ] Lectura de archivo por argumento CLI
- [ ] Guardar archivo (ctrl+s)
- [ ] Salir (ctrl+x)

### Fase 2: Status Bar
- [ ] StatusBar component (posición fija abajo)
- [ ] Word count: `123 words`
- [ ] Posición cursor: `Ln 12, Col 45`
- [ ] Toggle visibilidad (ctrl+b)

### Fase 3: Markdown
- [ ] Parser con swift-markdown (AST)
- [ ] MarkdownPreview con estilos ANSI (bold, italic, colores)
- [ ] Toggle modo plano ↔ renderizado (ctrl+r)
- [ ] Modo renderizado es solo lectura (preview)

## Desafíos Técnicos

### 1. Editor Multilínea Custom
SwiftTUI solo provee `TextField` (1 línea). Necesitamos crear `TextEditorControl`:
- Múltiples líneas con scroll
- Navegación con flechas
- Inserción/borrado de texto
- Cursor visible

### 2. Captura de Ctrl+
Extender el manejo de input en SwiftTUI para interceptar:
- `\u{13}` → ctrl+s
- `\u{18}` → ctrl+x  
- `\u{12}` → ctrl+r
- `\u{02}` → ctrl+b

### 3. Markdown Render en TUI
Convertir AST de swift-markdown a `Text` con atributos:
- Headers → colores/bold
- **bold** → `.bold()`
- *italic* → `.italic()`
- `code` → color diferente
- Links → subrayado + color

## Uso

```bash
# Abrir archivo existente
editxr documento.md

# Crear archivo nuevo
editxr nuevo.md
```

## Referencias

- [SwiftTUI](https://github.com/rensbreur/SwiftTUI) - Framework TUI
- [swift-markdown](https://github.com/apple/swift-markdown) - Parser Markdown
- [iA Writer](https://ia.net/writer) - Inspiración de diseño
