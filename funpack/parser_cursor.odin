package funpack

Sub_Parse_Error :: enum {
	None,
	Unexpected_Token,
	Unexpected_End,
	Wrong_Case,
}

Cursor :: struct($T: typeid, $K: typeid) {
	tokens: []T,
	pos:    int,
}

cursor_at_end :: proc(c: ^Cursor($T, $K)) -> bool {
	return c.pos >= len(c.tokens)
}

cursor_peek :: proc(c: ^Cursor($T, $K)) -> T {
	if cursor_at_end(c) {
		return T{}
	}
	return c.tokens[c.pos]
}

cursor_peek_kind :: proc(c: ^Cursor($T, $K)) -> K {
	return cursor_peek(c).kind
}

cursor_peek_kind_at :: proc(c: ^Cursor($T, $K), ahead: int) -> K {
	idx := c.pos + ahead
	if idx >= len(c.tokens) {
		return K{}
	}
	return c.tokens[idx].kind
}

cursor_advance :: proc(c: ^Cursor($T, $K)) -> (tok: T, err: Sub_Parse_Error) {
	if cursor_at_end(c) {
		return T{}, .Unexpected_End
	}
	tok = c.tokens[c.pos]
	c.pos += 1
	return tok, .None
}

cursor_expect :: proc(c: ^Cursor($T, $K), kind: K) -> (tok: T, err: Sub_Parse_Error) {
	tok = cursor_advance(c) or_return
	if tok.kind != kind {
		return T{}, .Unexpected_Token
	}
	return tok, .None
}

cursor_skip_kinds :: proc(c: ^Cursor($T, $K), kinds: ..K) {
	skip: for !cursor_at_end(c) {
		k := c.tokens[c.pos].kind
		for want in kinds {
			if k == want {
				c.pos += 1
				continue skip
			}
		}
		break
	}
}
