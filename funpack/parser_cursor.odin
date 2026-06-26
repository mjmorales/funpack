// Shared LL(1) parser cursor for the three funpack sub-languages — .fpm
// (modeling), .flvl (levels), and .fui (UI templates). Each sub-language parser
// drives an identical token cursor — a {tokens, pos} struct, a four-arm error
// enum, and peek/advance/expect helpers — so the mechanism lives here once and
// each sub-language file keeps only its grammar productions.
//
// The cursor is parametric over the token struct ($T) AND its kind enum ($K).
// $K is carried even though no field stores it: binding it on the per-language
// alias (e.g. `Fpm_Parser :: Cursor(Fpm_Token, Fpm_Token_Kind)`) is what lets
// `cursor_peek_kind` return the real kind type and lets a call-site comparison
// like `cursor_peek_kind(p) == .R_Brace` resolve the implicit selector against K.
//
// What stays per-language and why it cannot be hoisted here:
//   - `expect`/`skip` keep a thin typed facade per sub-language because Odin
//     cannot seed an implicit enum selector (`.R_Brace`) through a polymorphic
//     proc's `kind: K` parameter — only a facade whose parameter is the concrete
//     kind type gives the selector its expected type. The facade forwards to
//     `cursor_expect`/`cursor_skip_kinds`, so the logic is still single-sourced.
//   - `expect_upper`/`expect_lower` stay per-language because the case model
//     genuinely differs: .fpm splits case into two token KINDS (Upper_Ident /
//     Lower_Ident), while .flvl/.fui carry one Ident kind plus a `case_class`
//     FIELD. That is a grammar fact, not boilerplate, so each parser owns it.
package funpack

// Sub_Parse_Error is the closed verdict set shared by the three sub-language
// cursors: a token out of grammar position (Unexpected_Token), input ending
// mid-production (Unexpected_End), or an identifier whose initial-case is wrong
// for its position (Wrong_Case, lexical-core.ebnf §2). It is distinct from the
// richer `.fun` Parse_Error (parser.odin) by design — the sub-languages reject
// on exactly these three shapes, never the .fun directive/migrate verdicts. The
// per-language names (Fpm_Parse_Error, Flvl_Parse_Error, Fui_Parse_Error) alias
// this type, so a production reads in its own vocabulary over one shared enum.
Sub_Parse_Error :: enum {
	None,
	Unexpected_Token,
	Unexpected_End,
	Wrong_Case,
}

// Cursor is the token stream plus a read position. $K (the kind enum) is a type
// parameter, not a field — see the file header for why binding it on the alias
// matters. Every sub-language Token_Kind has Invalid as its zero member, so the
// zero token `T{}` and zero kind `K{}` are the natural end-of-input sentinels.
Cursor :: struct($T: typeid, $K: typeid) {
	tokens: []T,
	pos:    int,
}

cursor_at_end :: proc(c: ^Cursor($T, $K)) -> bool {
	return c.pos >= len(c.tokens)
}

// cursor_peek reports the zero token (kind == Invalid) at end of input so a kind
// check fails closed without a separate end test — the family-wide convention.
cursor_peek :: proc(c: ^Cursor($T, $K)) -> T {
	if cursor_at_end(c) {
		return T{}
	}
	return c.tokens[c.pos]
}

cursor_peek_kind :: proc(c: ^Cursor($T, $K)) -> K {
	return cursor_peek(c).kind
}

// cursor_peek_kind_at reports the kind `ahead` tokens past the cursor — the
// bounded lookahead the not-LL(1) named-argument forms need — Invalid at or past
// end so the check fails closed.
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

// cursor_skip_kinds consumes a run of any of `kinds` at the cursor — the
// separator-skip primitive the per-language facades build their Sep rule on
// (.fpm/.flvl: Newline|Comma; the Newline-only variant passes a single kind).
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
