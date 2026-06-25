# tree-sitter-funpack — .fpm (stub)

Lexical **stub** grammar for the .fpm modeling DSL (model/rig blocks, bake-time). Recognises comments, strings, numbers, and
punctuation for baseline highlighting; it does not yet model structure.

- **Source of truth:** `grammar/fpm.ebnf` (+ `grammar/lexical-core.ebnf`)
- **Backlog task:** `tree-sitter-grammar-for-fpm-mo-mqtpjqjr`
- **To implement:** replace `grammar.js` with a structural grammar mirroring the
  EBNF (see `../fun/` and `../fcfg/`), add `fpm` to `../scripts/check-corpus.sh`,
  and ship `queries/` + `test/corpus/`.
