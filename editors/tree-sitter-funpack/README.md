# tree-sitter-funpack

tree-sitter grammars for the funpack file-type family — one parser per file type,
sharing a single lexical core. Editor syntax highlighting and structural selection for
`.fun` and the surrounding config/asset DSLs.

Governed by ADR `.prove/decisions/tree-sitter-funpack-topology.md`: uniform tree-sitter
(not TextMate), one in-monorepo subtree (not a satellite repo), a shared lexical-core
helper, and a corpus-test drift gate.

## The grammar family

| Dir | Ext | What it is | Status |
|-----|-----|-----------|--------|
| `fun/` | `.fun` / `.gen.fun` | the language | **implemented** |
| `fcfg/` | `.fcfg` | project/entrypoint/build/tags config | **implemented** |
| `fpm/` | `.fpm` | modeling DSL (bake-time) | stub |
| `flvl/` | `.flvl` | level DSL | stub |
| `fui/` | `.fui` | UI template DSL | stub |
| `tiles/` | `.tiles` | tileset spec | stub |
| `atlas/` | `.atlas` | sprite-sheet slice spec | stub |
| `manifest/` | `.manifest` | asset index (generated) | stub |
| `common/` | — | shared lexical core + stub factory | — |

Each grammar dir holds its own `grammar.js`, `tree-sitter.json`, `queries/`, and
`test/corpus/`, and builds its own parser. `common/lexical-core.js` is the one source
of token shapes (mirrors `grammar/lexical-core.ebnf`); stubs share
`common/stub.js`, a lexical-only grammar (comments/strings/numbers, never ERRORs)
that gives baseline highlighting until a structural grammar is authored.

## Source of truth & lockstep

The grammars MIRROR `grammar/*.ebnf`; they do NOT reuse the Odin compiler frontend at
runtime (that is the LSP's job — see decision `lsp-odin-in-process-subcommand`). Because
the editor parser is separate, drift against the compiler grammar is the central risk.
The gate is `scripts/check-corpus.sh`: it parses every real source of each implemented
file type in the repo and fails on any `ERROR`/`MISSING` node.

**When you change `grammar/<type>.ebnf`, update `editors/tree-sitter-funpack/<type>/`
in the same change and re-run the drift gate.**

## Build, test, drift-gate

```sh
npm install                                   # provisions the tree-sitter CLI locally
cd fun  && ../node_modules/.bin/tree-sitter test
cd fcfg && ../node_modules/.bin/tree-sitter test
scripts/check-corpus.sh                       # drift gate over all real .fun/.fcfg
```

`task editors:check` runs the drift gate from the repo root.

## Editor install

The grammars live in a repo subpath; every modern editor's grammar registry supports
fetching a grammar from a subdirectory. The generated parser (`src/parser.c`) is not
committed — install paths below run `tree-sitter generate` (the CLI does this for you).

### Neovim (nvim-treesitter)

```lua
local parsers = require("nvim-treesitter.parsers").get_parser_configs()
parsers.fun = {
  install_info = {
    url = "https://github.com/mjmorales/funpack",
    location = "editors/tree-sitter-funpack/fun",
    files = { "src/parser.c", "src/scanner.c" },   -- .fun has an external scanner
    branch = "main",
  },
  filetype = "fun",
}
parsers.fcfg = {
  install_info = {
    url = "https://github.com/mjmorales/funpack",
    location = "editors/tree-sitter-funpack/fcfg",
    files = { "src/parser.c" },
    branch = "main",
  },
  filetype = "fcfg",
}
```
Then `:TSInstall fun fcfg` and copy each `queries/` into your runtimepath
`queries/<lang>/`.

### Helix (`languages.toml`)

```toml
[[grammar]]
name = "fun"
source = { git = "https://github.com/mjmorales/funpack", subpath = "editors/tree-sitter-funpack/fun", rev = "main" }

[[language]]
name = "fun"
scope = "source.fun"
file-types = ["fun"]
grammar = "fun"
```
Run `hx --grammar fetch && hx --grammar build`; place `queries/` under
`runtime/queries/fun/`.

### Zed / VS Code

Zed extensions reference a grammar by repo + subpath in `extension.toml`; a VS Code
extension can bundle the generated parser or use the
[tree-sitter](https://github.com/tree-sitter/tree-sitter) WASM build
(`tree-sitter build --wasm`). Map `.fun → source.fun`, `.fcfg → source.fcfg`.

## Simplifications (this is an editor parser, not the compiler)

- **Newlines are whitespace `extras`, not significant separators.** funpack's real
  separator is newline-or-comma with implicit line joining (lexical-core §8). Rather
  than a full newline scanner, `.fun` uses a tiny external scanner that asserts a
  postfix call/index bracket is on the same line as its callee — enough to stop a call
  greedily spanning a statement/match-arm boundary — and bracketed lists accept
  newline-or-comma. `.fcfg` and the stubs need no scanner.
- **Directive/test string args are raw** (no interpolation), so a `@doc` containing
  `{ … }` or `\"` is literal text.

These keep the grammars scanner-light while still parsing every real source in the repo
with zero ERROR nodes.
