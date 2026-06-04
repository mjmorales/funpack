package funpack

import "core:testing"

@(test)
test_lex_trivial_assert_token_kinds :: proc(t: ^testing.T) {
	tokens := stage_lex("test \"n\" {\nassert to_fixed(2) == 2.0\n}\n")
	kinds := [?]Token_Kind{
		.Test, .String_Lit, .L_Brace, .Newline,
		.Assert, .Ident, .L_Paren, .Int_Lit, .R_Paren, .Eq_Eq, .Fixed_Lit, .Newline,
		.R_Brace, .Newline,
	}
	testing.expect_value(t, len(tokens), len(kinds))
	for kind, i in kinds {
		testing.expect_value(t, tokens[i].kind, kind)
	}
}

@(test)
test_lex_literal_values :: proc(t: ^testing.T) {
	tokens := stage_lex("42 2.5")
	testing.expect_value(t, len(tokens), 2)
	testing.expect_value(t, tokens[0].kind, Token_Kind.Int_Lit)
	testing.expect_value(t, tokens[0].int_value, 42)
	testing.expect_value(t, tokens[1].kind, Token_Kind.Fixed_Lit)
	testing.expect_value(t, tokens[1].fixed_bits, Fixed(5 << 31))
}

@(test)
test_lex_single_equals_is_invalid :: proc(t: ^testing.T) {
	// `=` is binding, never equality (spec §02); the thin lexis has no
	// binding form, so a lone `=` is an Invalid token.
	tokens := stage_lex("=")
	testing.expect_value(t, len(tokens), 1)
	testing.expect_value(t, tokens[0].kind, Token_Kind.Invalid)
}

@(test)
test_lex_unterminated_string_is_invalid :: proc(t: ^testing.T) {
	tokens := stage_lex("\"abc")
	testing.expect_value(t, len(tokens), 1)
	testing.expect_value(t, tokens[0].kind, Token_Kind.Invalid)
}
