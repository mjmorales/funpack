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
test_lex_single_equals_is_binding :: proc(t: ^testing.T) {
	// `=` is binding, never equality (spec §02) — a distinct token from ==.
	tokens := stage_lex("=")
	testing.expect_value(t, len(tokens), 1)
	testing.expect_value(t, tokens[0].kind, Token_Kind.Eq)
}

@(test)
test_lex_unterminated_string_is_invalid :: proc(t: ^testing.T) {
	tokens := stage_lex("\"abc")
	testing.expect_value(t, len(tokens), 1)
	testing.expect_value(t, tokens[0].kind, Token_Kind.Invalid)
}

expect_kinds :: proc(t: ^testing.T, tokens: []Token, kinds: []Token_Kind) {
	testing.expect_value(t, len(tokens), len(kinds))
	if len(tokens) != len(kinds) {
		return
	}
	for kind, i in kinds {
		testing.expect_value(t, tokens[i].kind, kind)
	}
}

@(test)
test_lex_import_member_group :: proc(t: ^testing.T) {
	tokens := stage_lex("import engine.math.{Vec2, abs}\n")
	expect_kinds(t, tokens, []Token_Kind{
		.Import, .Ident, .Dot, .Ident, .Dot, .L_Brace,
		.Ident, .Comma, .Ident, .R_Brace, .Newline,
	})
}

@(test)
test_lex_record_literal :: proc(t: ^testing.T) {
	tokens := stage_lex("Vec2{x: 3.0, y: 4.0}")
	expect_kinds(t, tokens, []Token_Kind{
		.Ident, .L_Brace, .Ident, .Colon, .Fixed_Lit, .Comma,
		.Ident, .Colon, .Fixed_Lit, .R_Brace,
	})
}

@(test)
test_lex_variant_selector :: proc(t: ^testing.T) {
	tokens := stage_lex("Option::Some(3.0)")
	expect_kinds(t, tokens, []Token_Kind{
		.Ident, .Colon_Colon, .Ident, .L_Paren, .Fixed_Lit, .R_Paren,
	})
}

@(test)
test_lex_lambda_header_list_and_unary_minus :: proc(t: ^testing.T) {
	tokens := stage_lex("fold([1.0, -1.0], Fixed.MAX, fn(acc, x) { return acc + x })")
	expect_kinds(t, tokens, []Token_Kind{
		.Ident, .L_Paren, .L_Bracket, .Fixed_Lit, .Comma, .Minus, .Fixed_Lit, .R_Bracket,
		.Comma, .Ident, .Dot, .Ident, .Comma,
		.Fn, .L_Paren, .Ident, .Comma, .Ident, .R_Paren,
		.L_Brace, .Return, .Ident, .Plus, .Ident, .R_Brace, .R_Paren,
	})
}

@(test)
test_lex_let_binding :: proc(t: ^testing.T) {
	tokens := stage_lex("let v = Vec3{x: 1.0}\n")
	expect_kinds(t, tokens, []Token_Kind{
		.Let, .Ident, .Eq, .Ident, .L_Brace, .Ident, .Colon, .Fixed_Lit, .R_Brace, .Newline,
	})
}

@(test)
test_lex_comparison_arrow_directive_ops :: proc(t: ^testing.T) {
	tokens := stage_lex("== != < <= > >= -> = @ % *")
	expect_kinds(t, tokens, []Token_Kind{
		.Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq, .Arrow, .Eq, .At, .Percent, .Star,
	})
}

@(test)
test_lex_no_comment_production :: proc(t: ^testing.T) {
	// P6: the lexer has no comment production — `//` is two division
	// glyphs and the rest of the line lexes as ordinary tokens, never a
	// swallowed span.
	tokens := stage_lex("// not a comment\n")
	expect_kinds(t, tokens, []Token_Kind{
		.Slash, .Slash, .Ident, .Ident, .Ident, .Newline,
	})
}
