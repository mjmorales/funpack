package funpack

import "core:testing"

@(test)
test_parse_module_doc :: proc(t: ^testing.T) {
	tokens := stage_lex("@doc(\"the module doc\")\nimport engine.list.fold\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, ast.module_doc, "the module doc")
}

@(test)
test_parse_per_test_doc_attaches :: proc(t: ^testing.T) {
	tokens := stage_lex("@doc(\"module\")\nimport assets\n@doc(\"the test doc\")\ntest \"x\" {\n}\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, ast.module_doc, "module")
	testing.expect_value(t, len(ast.tests), 1)
	testing.expect_value(t, ast.tests[0].doc, "the test doc")
}

@(test)
test_parse_import_whole_module :: proc(t: ^testing.T) {
	tokens := stage_lex("import assets\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.imports), 1)
	testing.expect_value(t, len(ast.imports[0].segments), 1)
	testing.expect_value(t, ast.imports[0].segments[0], "assets")
	testing.expect_value(t, len(ast.imports[0].members), 0)
}

@(test)
test_parse_import_single_member :: proc(t: ^testing.T) {
	tokens := stage_lex("import engine.prelude.Option\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.imports[0].segments), 3)
	testing.expect_value(t, ast.imports[0].segments[2], "Option")
	testing.expect_value(t, len(ast.imports[0].members), 0)
}

@(test)
test_parse_import_member_group :: proc(t: ^testing.T) {
	tokens := stage_lex("import engine.math.{Vec2, abs, MAX}\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.imports[0].segments), 2)
	testing.expect_value(t, ast.imports[0].segments[1], "math")
	testing.expect_value(t, len(ast.imports[0].members), 3)
	testing.expect_value(t, ast.imports[0].members[0], "Vec2")
	testing.expect_value(t, ast.imports[0].members[2], "MAX")
}

@(test)
test_parse_import_group_newline_separated :: proc(t: ^testing.T) {
	// Members separate by `,` or newline — both legal (spec §02).
	tokens := stage_lex("import engine.math.{\n  Vec2\n  abs,\n  fold\n}\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.imports[0].members), 3)
}

@(test)
test_parse_import_interior_segment_wrong_case :: proc(t: ^testing.T) {
	// An interior path segment is a module name — snake_case only.
	tokens := stage_lex("import Engine.math.fold\n")
	_, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_test_body_let_then_assert :: proc(t: ^testing.T) {
	tokens := stage_lex("test \"quat\" {\nlet v = 1.0\nassert to_fixed(2) == 2.0\n}\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.tests[0].body), 2)
	let_node, is_let := ast.tests[0].body[0].(Let_Node)
	testing.expect(t, is_let)
	testing.expect_value(t, let_node.name, "v")
	_, value_is_fixed := let_node.value.(^Fixed_Lit_Expr)
	testing.expect(t, value_is_fixed)
	_, is_assert := ast.tests[0].body[1].(Assert_Node)
	testing.expect(t, is_assert)
}

@(test)
test_parse_let_wrong_case_name :: proc(t: ^testing.T) {
	tokens := stage_lex("test \"x\" {\nlet Vec = 1.0\n}\n")
	_, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_match_well_formed :: proc(t: ^testing.T) {
	// A well-formed match over the minimal pattern set — variant with
	// binders, bare variant, wildcard — parses to Parse_Error.None
	// (spec §02 §5).
	source := "match seen {\n" +
		"  Option::Some(p) => p\n" +
		"  Option::None => 0\n" +
		"  _ => 1\n" +
		"}\n"
	p := Parser{tokens = stage_lex(source)}
	expr, err := parse_match_from_keyword(&p)
	testing.expect_value(t, err, Parse_Error.None)
	m, is_match := expr.(^Match_Expr)
	testing.expect(t, is_match)
	if !is_match {
		return
	}
	testing.expect_value(t, len(m.arms), 3)
	testing.expect_value(t, m.arms[0].pattern.kind, Pattern_Kind.Variant_Binds)
	testing.expect_value(t, m.arms[0].pattern.type_name, "Option")
	testing.expect_value(t, m.arms[0].pattern.variant, "Some")
	testing.expect_value(t, len(m.arms[0].pattern.binders), 1)
	testing.expect_value(t, m.arms[0].pattern.binders[0], "p")
	testing.expect_value(t, m.arms[1].pattern.kind, Pattern_Kind.Bare_Variant)
	testing.expect_value(t, m.arms[2].pattern.kind, Pattern_Kind.Wildcard)
	// The scrutinee is the bare value name, not a record literal off it.
	scrutinee, is_name := m.scrutinee.(^Name_Expr)
	testing.expect(t, is_name)
	if is_name {
		testing.expect_value(t, scrutinee.name, "seen")
	}
}

@(test)
test_parse_match_comma_separated_arms :: proc(t: ^testing.T) {
	// `,` is a legal arm separator (Sep), so the inline one-line form
	// parses too (spec §02 §5).
	expr, err := parse_expr_text("match self { Screen::Hud => 1, _ => 2 }")
	testing.expect_value(t, err, Parse_Error.None)
	m, is_match := expr.(^Match_Expr)
	testing.expect(t, is_match)
	if is_match {
		testing.expect_value(t, len(m.arms), 2)
	}
}

@(test)
test_parse_match_missing_arrow_rejected :: proc(t: ^testing.T) {
	// A malformed arm — the `=>` separator omitted — rejects at parse.
	expr, err := parse_expr_text("match seen {\n  Option::None 0\n}\n")
	testing.expect(t, err != .None)
	testing.expect(t, expr == nil)
}

@(test)
test_parse_match_bad_pattern_case_rejected :: proc(t: ^testing.T) {
	// A bad pattern — a snake_case head where the variant pattern demands
	// an UpperCamel enum type — rejects as Wrong_Case (spec §02).
	_, err := parse_expr_text("match seen {\n  option::None => 0\n}\n")
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

// parse_match_from_keyword consumes the leading `match` token then
// delegates to parse_match — mirroring how parse_atom dispatches the
// keyword, for a test that drives parse_match directly.
parse_match_from_keyword :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	expect(p, .Match) or_return
	return parse_match(p)
}

@(test)
test_parse_golden_prefix :: proc(t: ^testing.T) {
	// The golden file's opening shape: module doc, the three import
	// forms, a documented test block.
	source := "@doc(\"contract\")\n" +
		"import engine.prelude.Option\n" +
		"import engine.math.{to_fixed, pi}\n" +
		"import engine.list.fold\n" +
		"\n" +
		"@doc(\"literals\")\n" +
		"test \"literals and explicit conversion\" {\n" +
		"  assert to_fixed(2) == 2.0\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, ast.module_doc, "contract")
	testing.expect_value(t, len(ast.imports), 3)
	testing.expect_value(t, len(ast.tests), 1)
	testing.expect_value(t, ast.tests[0].doc, "literals")
	testing.expect_value(t, len(ast.tests[0].body), 1)
}
