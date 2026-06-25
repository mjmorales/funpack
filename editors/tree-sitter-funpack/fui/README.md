# tree-sitter-funpack — .fui (stub)

Lexical **stub** grammar for the .fui UI template DSL (screen/widgets, bind:/@event attrs). Recognises comments, strings, numbers, and
punctuation for baseline highlighting; it does not yet model structure.

- **Source of truth:** `grammar/fui.ebnf` (+ `grammar/lexical-core.ebnf`)
- **Backlog task:** `tree-sitter-grammar-for-fui-ui-mqtpjqo7`
- **To implement:** replace `grammar.js` with a structural grammar mirroring the
  EBNF (see `../fun/` and `../fcfg/`), add `fui` to `../scripts/check-corpus.sh`,
  and ship `queries/` + `test/corpus/`.
