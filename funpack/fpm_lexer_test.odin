package funpack

import "core:testing"

// The .fpm lexer is the second-language frontend (spec §16). These tests pin the
// token stream against the bake-time spellings the `.fun` lexer forbids: `//`
// comments, FLOAT literals, the `..` range operator, and the model/rig keyword
// set — and the UPPER/lower identifier split (lexical-core.ebnf §2).

@(test)
test_fpm_lex_keyword_set :: proc(t: ^testing.T) {
	// Every block/member keyword maps to its dedicated kind, not Lower_Ident.
	tokens := fpm_lex("model rig param emit anchor socket material collide skeleton part mirror clearance")
	kinds := [?]Fpm_Token_Kind {
		.Model, .Rig, .Param, .Emit, .Anchor, .Socket, .Material, .Collide,
		.Skeleton, .Part, .Mirror, .Clearance,
	}
	testing.expect_value(t, len(tokens), len(kinds))
	for kind, i in kinds {
		testing.expect_value(t, tokens[i].kind, kind)
	}
}

@(test)
test_fpm_lex_imperative_keywords :: proc(t: ^testing.T) {
	// The §16 §1 imperative-body openers — fn/let/return/for/in/at — are keywords.
	tokens := fpm_lex("fn let return for in at")
	kinds := [?]Fpm_Token_Kind{.Fn, .Let, .Return, .For, .In, .At}
	testing.expect_value(t, len(tokens), len(kinds))
	for kind, i in kinds {
		testing.expect_value(t, tokens[i].kind, kind)
	}
}

@(test)
test_fpm_lex_line_comment_is_dropped :: proc(t: ^testing.T) {
	// A `//` comment runs to end of line and is whitespace to the parser (§16 §1)
	// — never a token, the opposite of the `.fun` lexer's two-slash rejection.
	tokens := fpm_lex("rig // this is a comment\nKrognid")
	testing.expect_value(t, len(tokens), 3)
	testing.expect_value(t, tokens[0].kind, Fpm_Token_Kind.Rig)
	testing.expect_value(t, tokens[1].kind, Fpm_Token_Kind.Newline)
	testing.expect_value(t, tokens[2].kind, Fpm_Token_Kind.Upper_Ident)
	testing.expect_value(t, tokens[2].text, "Krognid")
}

@(test)
test_fpm_lex_float_literal :: proc(t: ^testing.T) {
	// A decimal is a Float_Lit in the float domain; a trailing `f` is the FLOAT
	// (render/visual) spelling, also a Float_Lit (lexical-core.ebnf §3).
	tokens := fpm_lex("0.7 1.5f 120")
	testing.expect_value(t, len(tokens), 3)
	testing.expect_value(t, tokens[0].kind, Fpm_Token_Kind.Float_Lit)
	testing.expect(t, abs(tokens[0].float_value - 0.7) < 1e-9, "0.7 float value")
	testing.expect_value(t, tokens[1].kind, Fpm_Token_Kind.Float_Lit)
	testing.expect(t, abs(tokens[1].float_value - 1.5) < 1e-9, "1.5f float value")
	testing.expect_value(t, tokens[2].kind, Fpm_Token_Kind.Int_Lit)
	testing.expect_value(t, tokens[2].int_value, 120)
}

@(test)
test_fpm_lex_range_is_not_decimal :: proc(t: ^testing.T) {
	// `0..3` is the range operator of an accumulating loop, NOT a float: it lexes
	// Int_Lit `0`, Dot_Dot, Int_Lit `3` — a decimal point is a single `.` before
	// a digit, which `..` is not.
	tokens := fpm_lex("0..3")
	testing.expect_value(t, len(tokens), 3)
	testing.expect_value(t, tokens[0].kind, Fpm_Token_Kind.Int_Lit)
	testing.expect_value(t, tokens[0].int_value, 0)
	testing.expect_value(t, tokens[1].kind, Fpm_Token_Kind.Dot_Dot)
	testing.expect_value(t, tokens[2].kind, Fpm_Token_Kind.Int_Lit)
	testing.expect_value(t, tokens[2].int_value, 3)
}

@(test)
test_fpm_lex_identifier_case_split :: proc(t: ^testing.T) {
	// The two-class split is decided by initial character alone: a lowercase head
	// is Lower_Ident, an uppercase head is Upper_Ident (lexical-core.ebnf §2).
	tokens := fpm_lex("torso_mesh TORSO")
	testing.expect_value(t, len(tokens), 2)
	testing.expect_value(t, tokens[0].kind, Fpm_Token_Kind.Lower_Ident)
	testing.expect_value(t, tokens[0].ident_case, Fpm_Ident_Case.Lower)
	testing.expect_value(t, tokens[1].kind, Fpm_Token_Kind.Upper_Ident)
	testing.expect_value(t, tokens[1].ident_case, Fpm_Ident_Case.Upper)
}

@(test)
test_fpm_lex_arrow_and_member_chain :: proc(t: ^testing.T) {
	// `->` is the fn return-type / mirror arrow; a leading-dot postfix transform
	// (`.up(0)`) lexes as Dot, Lower_Ident, parens.
	tokens := fpm_lex("-> .up(0)")
	kinds := [?]Fpm_Token_Kind{.Arrow, .Dot, .Lower_Ident, .L_Paren, .Int_Lit, .R_Paren}
	testing.expect_value(t, len(tokens), len(kinds))
	for kind, i in kinds {
		testing.expect_value(t, tokens[i].kind, kind)
	}
}

@(test)
test_fpm_lex_invalid_glyph :: proc(t: ^testing.T) {
	// The lexer is total: an unrecognized glyph is an Invalid token for the
	// parser to reject, never a silent skip.
	tokens := fpm_lex("rig ! Bad")
	testing.expect_value(t, len(tokens), 3)
	testing.expect_value(t, tokens[1].kind, Fpm_Token_Kind.Invalid)
}

@(test)
test_fpm_lex_newline_run_coalesces :: proc(t: ^testing.T) {
	// A whitespace-plus-newline run collapses to ONE Newline token (the grammar's
	// Sep), so blank lines between members are a single separator.
	tokens := fpm_lex("a\n\n\nb")
	testing.expect_value(t, len(tokens), 3)
	testing.expect_value(t, tokens[0].kind, Fpm_Token_Kind.Lower_Ident)
	testing.expect_value(t, tokens[1].kind, Fpm_Token_Kind.Newline)
	testing.expect_value(t, tokens[2].kind, Fpm_Token_Kind.Lower_Ident)
}
