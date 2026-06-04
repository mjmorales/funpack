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
	testing.expect(t, !let_node.value.is_equal)
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
