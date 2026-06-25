# tree-sitter-funpack — .tiles (stub)

Lexical **stub** grammar for the .tiles tileset DSL (tileset/tile members). Recognises comments, strings, numbers, and
punctuation for baseline highlighting; it does not yet model structure.

- **Source of truth:** `grammar/tiles.ebnf` (+ `grammar/lexical-core.ebnf`)
- **Backlog task:** `tree-sitter-grammar-for-tiles--mqtpjqqe`
- **To implement:** replace `grammar.js` with a structural grammar mirroring the
  EBNF (see `../fun/` and `../fcfg/`), add `tiles` to `../scripts/check-corpus.sh`,
  and ship `queries/` + `test/corpus/`.
