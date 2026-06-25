# tree-sitter-funpack — .manifest (stub)

Lexical **stub** grammar for the .manifest asset index (generated, INI shape). Recognises comments, strings, numbers, and
punctuation for baseline highlighting; it does not yet model structure.

- **Source of truth:** `grammar/manifest.ebnf` (+ `grammar/lexical-core.ebnf`)
- **Backlog task:** `tree-sitter-grammar-for-manife-mqtpjqut`
- **To implement:** replace `grammar.js` with a structural grammar mirroring the
  EBNF (see `../fun/` and `../fcfg/`), add `manifest` to `../scripts/check-corpus.sh`,
  and ship `queries/` + `test/corpus/`.
