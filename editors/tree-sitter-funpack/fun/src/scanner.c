#include "tree_sitter/parser.h"

// tree-sitter-funpack external scanner.
//
// One zero-width token: SAME_LINE. It succeeds iff the next significant character
// follows on the SAME line as the previous token (no newline in the intervening
// horizontal whitespace). The grammar gates a postfix call/index `(`/`[` behind it,
// encoding funpack's rule that a newline after a value TERMINATES the expression
// (lexical-core §8): `f(x)` is a call, but `expr⏎(y)` is two statements, not
// `expr(y)`. Leading-dot member chains (`a⏎.b`) are NOT gated — funpack joins a line
// that begins with `.`, so member access may cross a newline.
//
// Stateless: nothing to serialize across incremental edits.

enum TokenType { SAME_LINE };

void *tree_sitter_fun_external_scanner_create(void) { return NULL; }
void tree_sitter_fun_external_scanner_destroy(void *payload) { (void)payload; }
unsigned tree_sitter_fun_external_scanner_serialize(void *payload, char *buffer) {
  (void)payload; (void)buffer; return 0;
}
void tree_sitter_fun_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
  (void)payload; (void)buffer; (void)length;
}

bool tree_sitter_fun_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
  (void)payload;
  if (!valid_symbols[SAME_LINE]) {
    return false;
  }
  // Skip horizontal whitespace; a newline before the next token means "not same
  // line". Consuming the spaces is harmless — they are `extras` either way.
  for (;;) {
    int32_t c = lexer->lookahead;
    if (c == ' ' || c == '\t' || c == '\r' || c == '\f' || c == '\v') {
      lexer->advance(lexer, true);
    } else if (c == '\n') {
      return false;
    } else {
      break;
    }
  }
  // Succeed ONLY when the same-line token is a postfix bracket — `(` (call) or `[`
  // (index). `valid_symbols[SAME_LINE]` is over-inclusive (tree-sitter offers it
  // wherever it *could* appear), so without this guard the zero-width token would
  // fire before any value and shadow the real token.
  if (lexer->lookahead == '(' || lexer->lookahead == '[') {
    lexer->result_symbol = SAME_LINE;
    return true;
  }
  return false;
}
