package funpack

import "core:testing"

@(test)
test_fpm_lex_keyword_set :: proc(t: ^testing.T) {
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
	tokens := fpm_lex("fn let return for in at")
	kinds := [?]Fpm_Token_Kind{.Fn, .Let, .Return, .For, .In, .At}
	testing.expect_value(t, len(tokens), len(kinds))
	for kind, i in kinds {
		testing.expect_value(t, tokens[i].kind, kind)
	}
}

@(test)
test_fpm_lex_line_comment_is_dropped :: proc(t: ^testing.T) {
	tokens := fpm_lex("rig // this is a comment\nKrognid")
	testing.expect_value(t, len(tokens), 3)
	testing.expect_value(t, tokens[0].kind, Fpm_Token_Kind.Rig)
	testing.expect_value(t, tokens[1].kind, Fpm_Token_Kind.Newline)
	testing.expect_value(t, tokens[2].kind, Fpm_Token_Kind.Upper_Ident)
	testing.expect_value(t, tokens[2].text, "Krognid")
}

@(test)
test_fpm_lex_float_literal :: proc(t: ^testing.T) {
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
	tokens := fpm_lex("torso_mesh TORSO")
	testing.expect_value(t, len(tokens), 2)
	testing.expect_value(t, tokens[0].kind, Fpm_Token_Kind.Lower_Ident)
	testing.expect_value(t, tokens[0].ident_case, Fpm_Ident_Case.Lower)
	testing.expect_value(t, tokens[1].kind, Fpm_Token_Kind.Upper_Ident)
	testing.expect_value(t, tokens[1].ident_case, Fpm_Ident_Case.Upper)
}

@(test)
test_fpm_lex_arrow_and_member_chain :: proc(t: ^testing.T) {
	tokens := fpm_lex("-> .up(0)")
	kinds := [?]Fpm_Token_Kind{.Arrow, .Dot, .Lower_Ident, .L_Paren, .Int_Lit, .R_Paren}
	testing.expect_value(t, len(tokens), len(kinds))
	for kind, i in kinds {
		testing.expect_value(t, tokens[i].kind, kind)
	}
}

@(test)
test_fpm_lex_invalid_glyph :: proc(t: ^testing.T) {
	tokens := fpm_lex("rig ! Bad")
	testing.expect_value(t, len(tokens), 3)
	testing.expect_value(t, tokens[1].kind, Fpm_Token_Kind.Invalid)
}

@(test)
test_fpm_lex_newline_run_coalesces :: proc(t: ^testing.T) {
	tokens := fpm_lex("a\n\n\nb")
	testing.expect_value(t, len(tokens), 3)
	testing.expect_value(t, tokens[0].kind, Fpm_Token_Kind.Lower_Ident)
	testing.expect_value(t, tokens[1].kind, Fpm_Token_Kind.Newline)
	testing.expect_value(t, tokens[2].kind, Fpm_Token_Kind.Lower_Ident)
}
