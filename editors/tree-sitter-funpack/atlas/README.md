# tree-sitter-funpack — .atlas (stub)

Lexical **stub** grammar for the .atlas sprite-sheet slice DSL. Recognises comments, strings, numbers, and
punctuation for baseline highlighting; it does not yet model structure.

- **Source of truth:** `grammar/atlas.ebnf` (+ `grammar/lexical-core.ebnf`)
- **Backlog task:** `tree-sitter-grammar-for-atlas--mqtpjqsl`
- **To implement:** replace `grammar.js` with a structural grammar mirroring the
  EBNF (see `../fun/` and `../fcfg/`), add `atlas` to `../scripts/check-corpus.sh`,
  and ship `queries/` + `test/corpus/`.
