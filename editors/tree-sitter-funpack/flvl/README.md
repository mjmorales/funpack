# tree-sitter-funpack — .flvl (stub)

Lexical **stub** grammar for the .flvl level DSL (placements, prefabs, tilemap grids). Recognises comments, strings, numbers, and
punctuation for baseline highlighting; it does not yet model structure.

- **Source of truth:** `grammar/flvl.ebnf` (+ `grammar/lexical-core.ebnf`)
- **Backlog task:** `tree-sitter-grammar-for-flvl-l-mqtpjqm0`
- **To implement:** replace `grammar.js` with a structural grammar mirroring the
  EBNF (see `../fun/` and `../fcfg/`), add `flvl` to `../scripts/check-corpus.sh`,
  and ship `queries/` + `test/corpus/`.
