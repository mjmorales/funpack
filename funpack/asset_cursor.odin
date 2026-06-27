package funpack

import_expect :: proc(c: ^Cursor($T, $K), kind: K, mismatch: $E) -> (tok: T, err: E) {
	tok = cursor_peek(c)
	if tok.kind != kind {
		return T{}, mismatch
	}
	c.pos += 1
	return tok, E{}
}

import_skip_balanced_parens :: proc(c: ^Cursor($T, $K), lparen, rparen: K) -> Importer_Error {
	if cursor_peek_kind(c) != lparen {
		return .Malformed_Source
	}
	c.pos += 1
	depth := 1
	for depth > 0 {
		if cursor_at_end(c) {
			return .Malformed_Source
		}
		invalid: K
		#partial switch cursor_peek_kind(c) {
		case lparen:
			depth += 1
		case rparen:
			depth -= 1
		case invalid:
			return .Malformed_Source
		}
		c.pos += 1
	}
	return .None
}
