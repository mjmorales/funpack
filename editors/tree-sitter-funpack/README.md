# tree-sitter-funpack

tree-sitter grammars for the funpack file-type family, one parser per file type,
sharing a single lexical core. Editor syntax highlighting and structural selection
for `.fun` and the surrounding config/asset DSLs.

> Governed by ADR `.prove/decisions/tree-sitter-funpack-topology.md`. The full
> editor-install guide and the grammar-family map are filled in once the first
> grammars are green (see step 1.6 of the run).

## Layout

```
editors/tree-sitter-funpack/
├── common/lexical-core.js   # shared token classes + builders (mirrors grammar/lexical-core.ebnf)
├── fun/                     # the .fun language        (grammar/fun.ebnf)     [implemented]
├── fcfg/                    # the .fcfg config layer   (grammar/fcfg.ebnf)    [implemented]
├── fpm/ flvl/ fui/          # bake-time DSLs           [scaffolded stubs]
└── tiles/ atlas/ manifest/  # asset specs + index      [scaffolded stubs]
```

Each grammar dir holds its own `grammar.js`, `tree-sitter.json`, `queries/`, and
`test/corpus/`, and produces its own parser. The shared `common/` module is the one
source of token shapes.

## Source of truth & lockstep

The grammars MIRROR `grammar/*.ebnf` — they do NOT reuse the Odin compiler frontend at
runtime (that is the LSP's job: `lsp-odin-in-process-subcommand`). Because the editor
parser is a separate parser, drift against the compiler grammar is the central risk.
The drift gate is per-grammar **corpus tests** plus a **parse-the-corpus** check: every
real source file of that type in the repo must parse with zero `ERROR`/`MISSING` nodes.

When you change `grammar/<type>.ebnf`, update `editors/tree-sitter-funpack/<type>/` in
the same change and re-run the corpus gate.

## Build & test

```sh
npm install                          # provisions the tree-sitter CLI locally
cd fun && tree-sitter generate && tree-sitter test
cd ../fcfg && tree-sitter generate && tree-sitter test
```

## Simplifications (editor parser, not the compiler)

- **Newlines are whitespace `extras`**, not significant separators. funpack's real
  separator is newline-or-comma with implicit line joining (lexical-core §8), which a
  faithful lexer would model with an external scanner. For highlighting we drop the
  scanner and make element separators optional commas — accurate enough to highlight and
  to parse real sources cleanly, without the scanner's maintenance cost.
