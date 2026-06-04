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
test_lex_newline_suppressed_in_list :: proc(t: ^testing.T) {
	tokens := stage_lex("[1.0,\n  2.0]\n")
	expect_kinds(t, tokens, []Token_Kind{
		.L_Bracket, .Fixed_Lit, .Comma, .Fixed_Lit, .R_Bracket, .Newline,
	})
}

@(test)
test_lex_newline_suppressed_in_record_literal :: proc(t: ^testing.T) {
	tokens := stage_lex("Vec2{x: 1.0,\n  y: 2.0}\n")
	expect_kinds(t, tokens, []Token_Kind{
		.Ident, .L_Brace, .Ident, .Colon, .Fixed_Lit, .Comma,
		.Ident, .Colon, .Fixed_Lit, .R_Brace, .Newline,
	})
}

@(test)
test_lex_newline_suppressed_in_call_args :: proc(t: ^testing.T) {
	tokens := stage_lex("clamp(5.0,\n  0.0,\n  3.0)\n")
	expect_kinds(t, tokens, []Token_Kind{
		.Ident, .L_Paren, .Fixed_Lit, .Comma, .Fixed_Lit, .Comma, .Fixed_Lit, .R_Paren, .Newline,
	})
}

@(test)
test_lex_newline_preserved_at_statement_boundary :: proc(t: ^testing.T) {
	tokens := stage_lex("let a = 1.0\nlet b = 2.0\n")
	expect_kinds(t, tokens, []Token_Kind{
		.Let, .Ident, .Eq, .Fixed_Lit, .Newline,
		.Let, .Ident, .Eq, .Fixed_Lit, .Newline,
	})
}

@(test)
test_lex_newline_preserved_in_block_braces :: proc(t: ^testing.T) {
	// A block's interior is a statement sequence (spec §02), so its
	// newlines terminate statements — only record-literal braces are
	// layout context.
	tokens := stage_lex("test \"n\" {\nassert 1.0 == 1.0\n}\n")
	expect_kinds(t, tokens, []Token_Kind{
		.Test, .String_Lit, .L_Brace, .Newline,
		.Assert, .Fixed_Lit, .Eq_Eq, .Fixed_Lit, .Newline,
		.R_Brace, .Newline,
	})
}

@(test)
test_lex_newline_joined_before_leading_dot :: proc(t: ^testing.T) {
	tokens := stage_lex("Quat.identity\n  .rotate(v)\n")
	expect_kinds(t, tokens, []Token_Kind{
		.Ident, .Dot, .Ident, .Dot, .Ident, .L_Paren, .Ident, .R_Paren, .Newline,
	})
}

@(test)
test_lex_block_inside_call_keeps_statement_newlines :: proc(t: ^testing.T) {
	// A lambda body nested in call args sits at paren depth > 0, so its
	// interior newlines are suppressed along with the argument layout —
	// the single-line body form the golden file uses is unaffected.
	tokens := stage_lex("fold([],\n  z,\n  fn(acc, x) { return acc })\n")
	expect_kinds(t, tokens, []Token_Kind{
		.Ident, .L_Paren, .L_Bracket, .R_Bracket, .Comma, .Ident, .Comma,
		.Fn, .L_Paren, .Ident, .Comma, .Ident, .R_Paren,
		.L_Brace, .Return, .Ident, .R_Brace, .R_Paren, .Newline,
	})
}

@(test)
test_classify_ident_classes :: proc(t: ^testing.T) {
	testing.expect_value(t, classify_ident("Vec2"), Ident_Class.Upper_Camel)
	testing.expect_value(t, classify_ident("Option"), Ident_Class.Upper_Camel)
	testing.expect_value(t, classify_ident("to_fixed"), Ident_Class.Snake_Case)
	testing.expect_value(t, classify_ident("x"), Ident_Class.Snake_Case)
	testing.expect_value(t, classify_ident("MAX"), Ident_Class.Upper_Snake)
	testing.expect_value(t, classify_ident("UPPER_SNAKE"), Ident_Class.Upper_Snake)
	testing.expect_value(t, classify_ident("fooBar"), Ident_Class.Mixed)
	testing.expect_value(t, classify_ident("Foo_Bar"), Ident_Class.Mixed)
	// The sanctioned lowercase constants classify as plain snake_case —
	// the exception needs no special case in the taxonomy.
	testing.expect_value(t, classify_ident("pi"), Ident_Class.Snake_Case)
	testing.expect_value(t, classify_ident("tau"), Ident_Class.Snake_Case)
}

@(test)
test_lex_ident_carries_class :: proc(t: ^testing.T) {
	tokens := stage_lex("Vec2 to_fixed MAX")
	testing.expect_value(t, tokens[0].class, Ident_Class.Upper_Camel)
	testing.expect_value(t, tokens[1].class, Ident_Class.Snake_Case)
	testing.expect_value(t, tokens[2].class, Ident_Class.Upper_Snake)
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
