# funpack — VS Code / Cursor extension

Syntax highlighting for the funpack language family (`.fun`, `.gen.fun`, `.fcfg`) in
**Cursor** and VS Code. Two layers:

- **TextMate grammars** (`syntaxes/*.tmLanguage.json`) — instant base colouring of the
  lexical surface (keywords, strings, numbers, booleans, operators, the `@`-directive
  set). This is the layer VS Code/Cursor use natively.
- **tree-sitter semantic tokens** (`src/extension.ts`) — reuses the
  `editors/tree-sitter-funpack` grammars (compiled to WASM) and their `highlights.scm`
  queries to add the structural distinctions TextMate can't make: variable vs
  parameter vs property vs function vs method vs type vs constructor.

Cursor is a VS Code fork: it is TextMate-native and does **not** consume tree-sitter
grammars directly, so this extension is the bridge that makes the tree-sitter family
usable there. The same `.wasm` + queries also serve nvim/Helix/Zed natively (see
`../tree-sitter-funpack`).

## Install in Cursor

### From a packaged `.vsix` (recommended)

```sh
cd editors/vscode-funpack
npm install
npm run compile
npx @vscode/vsce package     # produces funpack-<version>.vsix
cursor --install-extension funpack-0.1.0.vsix
```

Or: Cursor → Extensions → `⋯` menu → **Install from VSIX…** → pick the file. Reload.

### From source (development)

Open `editors/vscode-funpack/` in Cursor and press **F5** to launch an Extension
Development Host with the extension loaded.

### Manual

Copy this folder (after `npm install && npm run compile`) into `~/.cursor/extensions/`
and reload.

## Seeing the semantic colours

Semantic highlighting must be on — it is by default for most themes
(`"editor.semanticHighlighting.enabled": true`). If types/params/properties aren't
distinctly coloured, set that in your settings. The TextMate base works regardless.

## Keeping it in lockstep

The bundled queries and WASM derive from `../tree-sitter-funpack` (the single source of
truth, mirroring `grammar/*.ebnf`). After changing a grammar:

```sh
npm run build-wasm   # rebuild wasm/ (needs the tree-sitter CLI + docker emscripten)
npm run sync         # copy the latest highlights.scm into queries/
npm run compile
```

The TextMate grammars are maintained alongside; they are coarse (token classes, not
structure) by design — the semantic layer supplies structure.

## Layout

```
editors/vscode-funpack/
├── package.json                  # language + grammar contributions, semantic provider entry
├── language-configuration.json   # brackets / autoclose (.fun has no comments)
├── syntaxes/                     # TextMate grammars (base layer)
├── src/extension.ts              # tree-sitter semantic-tokens provider (augment layer)
├── queries/<id>/highlights.scm   # synced from ../tree-sitter-funpack/<id>/queries
└── wasm/tree-sitter-<id>.wasm    # built from ../tree-sitter-funpack/<id>
```
