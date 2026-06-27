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
test_parse_module_doc_blank_line_before_import :: proc(t: ^testing.T) {
	tokens := stage_lex("@doc(\"the module doc\")\n\nimport engine.list.fold\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, ast.module_doc, "the module doc")
}

@(test)
test_parse_module_doc_many_blank_lines_before_import :: proc(t: ^testing.T) {
	tokens := stage_lex("@doc(\"the module doc\")\n\n\n\nimport engine.list.fold\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, ast.module_doc, "the module doc")
}

@(test)
test_parse_first_doc_before_decl_not_module_doc :: proc(t: ^testing.T) {
	tokens := stage_lex("@doc(\"the data doc\")\n\ndata Pt { x: Int }\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, ast.module_doc, "")
	testing.expect_value(t, len(ast.datas), 1)
	testing.expect_value(t, ast.datas[0].doc, "the data doc")
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
test_stage_parse_located_anchors_post_advance_offender :: proc(t: ^testing.T) {
	_, verdict := stage_parse_located(stage_lex("thing widget { x: Int }\n"))
	testing.expect_value(t, verdict.err, Parse_Error.Wrong_Case)
	testing.expect_value(t, verdict.line, 1)
	testing.expect_value(t, verdict.col, 7)
}

@(test)
test_stage_parse_located_peek_reject_falls_back_to_stop_span :: proc(t: ^testing.T) {
	_, verdict := stage_parse_located(stage_lex("extern data X\n"))
	testing.expect_value(t, verdict.err, Parse_Error.Malformed_Extern)
	testing.expect_value(t, verdict.line, 1)
	testing.expect_value(t, verdict.col, 8)
}

@(test)
test_parse_import_carries_keyword_provenance :: proc(t: ^testing.T) {
	tokens := stage_lex("import assets\nimport engine.math.{Vec2}\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.imports), 2)
	testing.expect_value(t, ast.imports[0].line, 1)
	testing.expect_value(t, ast.imports[0].col, 1)
	testing.expect_value(t, ast.imports[1].line, 2)
	testing.expect_value(t, ast.imports[1].col, 1)
}

@(test)
test_parse_import_group_newline_separated :: proc(t: ^testing.T) {
	tokens := stage_lex("import engine.math.{\n  Vec2\n  abs,\n  fold\n}\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.imports[0].members), 3)
}

@(test)
test_parse_import_interior_segment_wrong_case :: proc(t: ^testing.T) {
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
test_parse_let_tuple_destructure :: proc(t: ^testing.T) {
	tokens := stage_lex("fn draw() -> Int {\n  let (a, b) = pair()\n  return a\n}\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	let_node, is_let := ast.fns[0].body[0].(Let_Node)
	testing.expect(t, is_let)
	testing.expect(t, let_node.is_tuple)
	testing.expect_value(t, let_node.name, "")
	testing.expect_value(t, len(let_node.names), 2)
	testing.expect_value(t, let_node.names[0], "a")
	testing.expect_value(t, let_node.names[1], "b")
}

@(test)
test_parse_let_tuple_destructure_three_binders :: proc(t: ^testing.T) {
	tokens := stage_lex("fn f() -> Int {\n  let (a, b, c) = triple()\n  return a\n}\n")
	ast, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.None)
	let_node, is_let := ast.fns[0].body[0].(Let_Node)
	testing.expect(t, is_let)
	testing.expect(t, let_node.is_tuple)
	testing.expect_value(t, len(let_node.names), 3)
}

@(test)
test_parse_let_tuple_destructure_wrong_case :: proc(t: ^testing.T) {
	tokens := stage_lex("fn f() -> Int {\n  let (A, b) = pair()\n  return b\n}\n")
	_, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_match_well_formed :: proc(t: ^testing.T) {
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
	testing.expect_value(t, len(m.arms[0].pattern.elements), 1)
	testing.expect_value(t, m.arms[0].pattern.elements[0].kind, Pattern_Kind.Bare_Binder)
	testing.expect_value(t, len(m.arms[0].pattern.elements[0].binders), 1)
	testing.expect_value(t, m.arms[0].pattern.elements[0].binders[0], "p")
	testing.expect_value(t, m.arms[1].pattern.kind, Pattern_Kind.Bare_Variant)
	testing.expect_value(t, m.arms[2].pattern.kind, Pattern_Kind.Wildcard)
	scrutinee, is_name := m.scrutinee.(^Name_Expr)
	testing.expect(t, is_name)
	if is_name {
		testing.expect_value(t, scrutinee.name, "seen")
	}
}

@(test)
test_parse_match_struct_payload_destructure :: proc(t: ^testing.T) {
	source := "match shape {\n" +
		"  Shape2::Box{size} => size\n" +
		"  _ => fallback\n" +
		"}\n"
	p := Parser{tokens = stage_lex(source)}
	expr, err := parse_match_from_keyword(&p)
	testing.expect_value(t, err, Parse_Error.None)
	m, is_match := expr.(^Match_Expr)
	testing.expect(t, is_match)
	if !is_match {
		return
	}
	testing.expect_value(t, len(m.arms), 2)
	pat := m.arms[0].pattern
	testing.expect_value(t, pat.kind, Pattern_Kind.Struct_Binds)
	testing.expect_value(t, pat.type_name, "Shape2")
	testing.expect_value(t, pat.variant, "Box")
	testing.expect_value(t, len(pat.binders), 1)
	testing.expect_value(t, pat.binders[0], "size")
	testing.expect_value(t, m.arms[1].pattern.kind, Pattern_Kind.Wildcard)
}

@(test)
test_parse_match_struct_payload_multi_field :: proc(t: ^testing.T) {
	expr, err := parse_expr_text("match shape { Shape2::Rect{w, h} => w, _ => h }")
	testing.expect_value(t, err, Parse_Error.None)
	m, is_match := expr.(^Match_Expr)
	testing.expect(t, is_match)
	if !is_match {
		return
	}
	pat := m.arms[0].pattern
	testing.expect_value(t, pat.kind, Pattern_Kind.Struct_Binds)
	testing.expect_value(t, len(pat.binders), 2)
	testing.expect_value(t, pat.binders[0], "w")
	testing.expect_value(t, pat.binders[1], "h")
}

@(test)
test_parse_match_struct_payload_wrong_case_field_rejected :: proc(t: ^testing.T) {
	_, err := parse_expr_text("match shape { Shape2::Box{Size} => 0, _ => 1 }")
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_match_comma_separated_arms :: proc(t: ^testing.T) {
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
	expr, err := parse_expr_text("match seen {\n  Option::None 0\n}\n")
	testing.expect(t, err != .None)
	testing.expect(t, expr == nil)
}

@(test)
test_parse_match_bad_pattern_case_rejected :: proc(t: ^testing.T) {
	_, err := parse_expr_text("match seen {\n  option::None => 0\n}\n")
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_match_on_bool_true_pattern_steers_to_if :: proc(t: ^testing.T) {
	_, err := parse_expr_text("match hit {\n  true => 1\n  false => 0\n}\n")
	testing.expect_value(t, err, Parse_Error.Bool_Pattern_Unsupported)
}

@(test)
test_parse_match_on_bool_false_first_arm_steers_to_if :: proc(t: ^testing.T) {
	_, err := parse_expr_text("match done {\n  false => 0\n  true => 1\n}\n")
	testing.expect_value(t, err, Parse_Error.Bool_Pattern_Unsupported)
}

@(test)
test_parse_fn_body_leading_binary_op_after_newline_rejected :: proc(t: ^testing.T) {
	source := "fn keep() -> Bool {\n  return a < b\n  and c < d\n}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Newline_Before_Binary_Op)
}

parse_match_from_keyword :: proc(p: ^Parser) -> (expr: Expr, err: Parse_Error) {
	match_tok := expect(p, .Match) or_return
	return parse_match(p, match_tok)
}

@(test)
test_parse_golden_prefix :: proc(t: ^testing.T) {
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

@(test)
test_parse_data_decl_with_fields :: proc(t: ^testing.T) {
	ast, err := stage_parse(stage_lex("data Board { w: Fixed, h: Fixed = 120.0 }\n"))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.datas), 1)
	d := ast.datas[0]
	testing.expect_value(t, d.name, "Board")
	testing.expect_value(t, d.kind, "")
	testing.expect_value(t, len(d.fields), 2)
	testing.expect_value(t, d.fields[0].name, "w")
	testing.expect_value(t, d.fields[0].type.name, "Fixed")
	testing.expect(t, !d.fields[0].has_default)
	testing.expect(t, d.fields[1].has_default)
}

@(test)
test_parse_enum_as_role_kind :: proc(t: ^testing.T) {
	ast, err := stage_parse(stage_lex("enum Steer: Axis { Move }\n"))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.enums), 1)
	e := ast.enums[0]
	testing.expect_value(t, e.name, "Steer")
	testing.expect_value(t, e.kind, "Axis")
	testing.expect_value(t, len(e.variants), 1)
	testing.expect_value(t, e.variants[0].name, "Move")
	testing.expect_value(t, e.variants[0].payload, Variant_Payload.Plain)
}

@(test)
test_parse_enum_payload_variants :: proc(t: ^testing.T) {
	source := "enum PathOp {\n" +
		"  Close\n" +
		"  MoveTo(Vec2)\n" +
		"  CubicTo{ c1: Vec2, to: Vec2 }\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	e := ast.enums[0]
	testing.expect_value(t, len(e.variants), 3)
	testing.expect_value(t, e.variants[0].payload, Variant_Payload.Plain)
	testing.expect_value(t, e.variants[1].payload, Variant_Payload.Tuple)
	testing.expect_value(t, len(e.variants[1].tuple), 1)
	testing.expect_value(t, e.variants[2].payload, Variant_Payload.Struct)
	testing.expect_value(t, len(e.variants[2].fields), 2)
}

@(test)
test_parse_variant_doc_carried :: proc(t: ^testing.T) {
	source := "@doc(\"A 2D draw command.\")\n" +
		"enum Draw {\n" +
		"  @doc(\"A filled rectangle.\")\n" +
		"  Rect{ at: Vec2, color: Color },\n" +
		"  @doc(\"A move-to op.\")\n" +
		"  MoveTo(Vec2),\n" +
		"  Close\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	if err != .None {
		return
	}
	e := ast.enums[0]
	testing.expect_value(t, e.doc, "A 2D draw command.")
	testing.expect_value(t, len(e.variants), 3)
	testing.expect_value(t, e.variants[0].doc, "A filled rectangle.")
	testing.expect_value(t, e.variants[0].payload, Variant_Payload.Struct)
	testing.expect_value(t, e.variants[1].doc, "A move-to op.")
	testing.expect_value(t, e.variants[1].payload, Variant_Payload.Tuple)
	testing.expect_value(t, e.variants[2].doc, "")
	testing.expect_value(t, e.variants[2].payload, Variant_Payload.Plain)
}

@(test)
test_parse_variant_doc_inline :: proc(t: ^testing.T) {
	source := "enum Side { @doc(\"The left side.\") Left, Right }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	if err != .None {
		return
	}
	e := ast.enums[0]
	testing.expect_value(t, len(e.variants), 2)
	testing.expect_value(t, e.variants[0].doc, "The left side.")
	testing.expect_value(t, e.variants[1].doc, "")
}

@(test)
test_parse_variant_gtag_rejected :: proc(t: ^testing.T) {
	source := "enum Side { @gtag(\"side\") Left, Right }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Variant_Directive_Wrong_Target)
}

@(test)
test_parse_variant_todo_rejected :: proc(t: ^testing.T) {
	source := "enum Side {\n  @todo(\"rename\", T-0042)\n  Left\n}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Variant_Directive_Wrong_Target)
}

@(test)
test_parse_variant_probe_rejected :: proc(t: ^testing.T) {
	source := "enum Side { @log(side) Left, Right }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Variant_Directive_Wrong_Target)
}

@(test)
test_parse_variant_expose_rejected :: proc(t: ^testing.T) {
	source := "enum Side { @expose Left, Right }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Variant_Directive_Wrong_Target)
}

@(test)
test_parse_variant_migrate_rejected :: proc(t: ^testing.T) {
	source := "enum Side { @migrate(from: \"L\") Left, Right }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Migrate_Wrong_Target)
}

@(test)
test_parse_variant_index_rejected :: proc(t: ^testing.T) {
	source := "enum Side { @index(Enemy.cell) Left, Right }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Index_Wrong_Target)
}

@(test)
test_parse_variant_doc_dangling_rejected :: proc(t: ^testing.T) {
	source := "enum Side {\n  Left\n  @doc(\"nothing follows\")\n}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Variant_Directive_Wrong_Target)
}

@(test)
test_contextual_keywords_legal_in_value_position :: proc(t: ^testing.T) {
	source := "test \"contextual words bind\" {\n" +
		"  let thing = 1\n" +
		"  let singleton = 2\n" +
		"  let data = 3\n" +
		"  let enum = 4\n" +
		"  let on = thing\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.tests), 1)
	body := ast.tests[0].body
	testing.expect_value(t, len(body), 5)
	names := [5]string{"thing", "singleton", "data", "enum", "on"}
	for want, idx in names {
		let_node, is_let := body[idx].(Let_Node)
		testing.expect(t, is_let)
		if is_let {
			testing.expect_value(t, let_node.name, want)
		}
	}
	on_let, on_is_let := body[4].(Let_Node)
	testing.expect(t, on_is_let)
	if on_is_let {
		name_expr, is_name := on_let.value.(^Name_Expr)
		testing.expect(t, is_name)
		if is_name {
			testing.expect_value(t, name_expr.name, "thing")
			testing.expect_value(t, name_expr.class, Ident_Class.Snake_Case)
		}
	}

	member_expr, member_err := parse_expr_text("s.data")
	testing.expect_value(t, member_err, Parse_Error.None)
	member, is_member := member_expr.(^Member_Expr)
	testing.expect(t, is_member)
	if is_member {
		testing.expect_value(t, member.member, "data")
	}

	field_ast, field_err := stage_parse(stage_lex("data Flags { enum: Bool, thing: Int }\n"))
	testing.expect_value(t, field_err, Parse_Error.None)
	testing.expect_value(t, len(field_ast.datas), 1)
	testing.expect_value(t, len(field_ast.datas[0].fields), 2)
	testing.expect_value(t, field_ast.datas[0].fields[0].name, "enum")
	testing.expect_value(t, field_ast.datas[0].fields[1].name, "thing")

	decl_ast, decl_err := stage_parse(stage_lex("thing Paddle { y: Fixed }\n"))
	testing.expect_value(t, decl_err, Parse_Error.None)
	testing.expect_value(t, len(decl_ast.things), 1)
	testing.expect_value(t, decl_ast.things[0].name, "Paddle")
	testing.expect(t, !decl_ast.things[0].is_singleton)
}

@(test)
test_query_mut_contextual_value_only :: proc(t: ^testing.T) {
	source := "test \"query and mut bind\" {\n" +
		"  let query = 1\n" +
		"  let mut = query\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.tests), 1)
	body := ast.tests[0].body
	testing.expect_value(t, len(body), 2)
	q_let, q_is := body[0].(Let_Node)
	testing.expect(t, q_is)
	if q_is {
		testing.expect_value(t, q_let.name, "query")
	}
	m_let, m_is := body[1].(Let_Node)
	testing.expect(t, m_is)
	if m_is {
		testing.expect_value(t, m_let.name, "mut")
		name_expr, is_name := m_let.value.(^Name_Expr)
		testing.expect(t, is_name)
		if is_name {
			testing.expect_value(t, name_expr.name, "query")
			testing.expect_value(t, name_expr.class, Ident_Class.Snake_Case)
		}
	}

	field_ast, field_err := stage_parse(stage_lex("data Q { query: Int, mut: Bool }\n"))
	testing.expect_value(t, field_err, Parse_Error.None)
	testing.expect_value(t, len(field_ast.datas), 1)
	testing.expect_value(t, len(field_ast.datas[0].fields), 2)
	testing.expect_value(t, field_ast.datas[0].fields[0].name, "query")
	testing.expect_value(t, field_ast.datas[0].fields[1].name, "mut")

	_, q_decl_err := stage_parse(stage_lex("query Recent { since: Int }\n"))
	testing.expect_value(t, q_decl_err, Parse_Error.Wrong_Case)
	_, m_decl_err := stage_parse(stage_lex("mut Board { score: Int }\n"))
	testing.expect_value(t, m_decl_err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_thing_and_singleton :: proc(t: ^testing.T) {
	source := "thing Ball { pos: Vec2, vel: Vec2 }\n" +
		"singleton Scoreboard { left: Int = 0, right: Int = 0 }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.things), 2)
	testing.expect_value(t, ast.things[0].name, "Ball")
	testing.expect(t, !ast.things[0].is_singleton)
	testing.expect_value(t, ast.things[1].name, "Scoreboard")
	testing.expect(t, ast.things[1].is_singleton)
	testing.expect(t, ast.things[1].fields[0].has_default)
}

@(test)
test_parse_signal_decl :: proc(t: ^testing.T) {
	ast, err := stage_parse(stage_lex("signal Goal { side: Side }\n"))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.signals), 1)
	testing.expect_value(t, ast.signals[0].name, "Goal")
	testing.expect_value(t, len(ast.signals[0].fields), 1)
	testing.expect_value(t, ast.signals[0].fields[0].type.name, "Side")
}

@(test)
test_parse_module_let_decl :: proc(t: ^testing.T) {
	ast, err := stage_parse(stage_lex("let BOARD: Board = Board{ w: 160.0, h: 120.0 }\n"))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.lets), 1)
	testing.expect_value(t, ast.lets[0].name, "BOARD")
	testing.expect_value(t, ast.lets[0].type.name, "Board")
	_, value_is_record := ast.lets[0].value.(^Record_Expr)
	testing.expect(t, value_is_record)
}

@(test)
test_parse_top_level_fn_multistatement_body :: proc(t: ^testing.T) {
	source := "fn advance(at: Vec2, vel: Vec2, dt: Fixed) -> Vec2 {\n" +
		"  let step = vel * dt\n" +
		"  return at + step\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.fns), 1)
	f := ast.fns[0]
	testing.expect_value(t, f.name, "advance")
	testing.expect_value(t, len(f.params), 3)
	testing.expect_value(t, f.params[2].name, "dt")
	testing.expect_value(t, f.return_type.name, "Vec2")
	testing.expect_value(t, len(f.body), 2)
	_, first_is_let := f.body[0].(Let_Node)
	testing.expect(t, first_is_let)
	_, second_is_return := f.body[1].(Return_Node)
	testing.expect(t, second_is_return)
}

@(test)
test_parse_fn_if_early_return_body :: proc(t: ^testing.T) {
	source := "fn goal_side(at: Vec2) -> Option[Side] {\n" +
		"  if at.x < 0.0 { return Option::Some(Side::Right) }\n" +
		"  return Option::None\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	testing.expect_value(t, len(f.body), 2)
	if_node, first_is_if := f.body[0].(If_Node)
	testing.expect(t, first_is_if)
	if first_is_if {
		_, cond_is_binary := if_node.cond.(^Binary_Expr)
		testing.expect(t, cond_is_binary)
		testing.expect_value(t, len(if_node.body), 1)
		_, body_is_return := if_node.body[0].(Return_Node)
		testing.expect(t, body_is_return)
	}
}

@(test)
test_parse_behavior_with_reserved_step :: proc(t: ^testing.T) {
	source := "behavior paddle_move on Paddle {\n" +
		"  fn step(self: Paddle, input: Input, time: Time) -> Paddle {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.behaviors), 1)
	b := ast.behaviors[0]
	testing.expect_value(t, b.name, "paddle_move")
	testing.expect_value(t, b.target, "Paddle")
	testing.expect_value(t, b.step.name, "step")
	testing.expect_value(t, len(b.step.params), 3)
	testing.expect_value(t, b.step.return_type.name, "Paddle")
}

@(test)
test_parse_behavior_non_step_entry_rejected :: proc(t: ^testing.T) {
	source := "behavior bad on Paddle {\n" +
		"  fn update(self: Paddle) -> Paddle {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_fn_stub_body :: proc(t: ^testing.T) {
	source := "fn serve(b: Ball) -> Ball @stub(Ball)\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.fns), 1)
	f := ast.fns[0]
	testing.expect_value(t, f.name, "serve")
	testing.expect_value(t, f.holed, true)
	testing.expect_value(t, f.hole_type.name, "Ball")
	testing.expect_value(t, f.has_fallback, false)
	testing.expect_value(t, len(f.body), 0)
}

@(test)
test_parse_fn_stub_body_with_fallback :: proc(t: ^testing.T) {
	source := "fn speed() -> Fixed @stub(Fixed, 1.5)\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	testing.expect_value(t, f.holed, true)
	testing.expect_value(t, f.hole_type.name, "Fixed")
	testing.expect_value(t, f.has_fallback, true)
	_, fallback_is_fixed := f.fallback.(^Fixed_Lit_Expr)
	testing.expect(t, fallback_is_fixed)
}

@(test)
test_parse_fn_stub_body_generic_hole_type :: proc(t: ^testing.T) {
	source := "fn pick() -> Option[Side] @stub(Option[Side])\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	testing.expect_value(t, f.holed, true)
	testing.expect_value(t, f.hole_type.name, "Option")
	testing.expect_value(t, len(f.hole_type.args), 1)
	testing.expect_value(t, f.hole_type.args[0].name, "Side")
}

@(test)
test_parse_behavior_step_stub_body :: proc(t: ^testing.T) {
	source := "behavior serve on Ball {\n" +
		"  fn step(self: Ball) -> Ball @stub(Ball)\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.behaviors), 1)
	b := ast.behaviors[0]
	testing.expect_value(t, b.step.name, "step")
	testing.expect_value(t, b.step.holed, true)
	testing.expect_value(t, b.step.hole_type.name, "Ball")
	testing.expect_value(t, b.step.has_fallback, false)
}

@(test)
test_parse_stub_as_prefix_directive_rejected :: proc(t: ^testing.T) {
	source := "@stub(Ball)\nfn serve(b: Ball) -> Ball {\n  return b\n}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_stub_inside_block_rejected :: proc(t: ^testing.T) {
	source := "fn serve(b: Ball) -> Ball {\n  @stub(Ball)\n}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_stub_missing_type_rejected :: proc(t: ^testing.T) {
	source := "fn serve(b: Ball) -> Ball @stub()\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_non_stub_directive_in_body_position_rejected :: proc(t: ^testing.T) {
	source := "fn serve(b: Ball) -> Ball @doc(\"not a body\")\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_stub_expr_atom_bare :: proc(t: ^testing.T) {
	source := "fn boost(base: Fixed) -> Fixed {\n  return base + @stub(Fixed)\n}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.fns), 1)
	f := ast.fns[0]
	testing.expect_value(t, f.holed, false)
	testing.expect_value(t, len(f.body), 1)
	ret, is_return := f.body[0].(Return_Node)
	testing.expect(t, is_return)
	if !is_return {
		return
	}
	binary, is_binary := ret.value.(^Binary_Expr)
	testing.expect(t, is_binary)
	if !is_binary {
		return
	}
	hole, is_stub := binary.rhs.(^Stub_Expr)
	testing.expect(t, is_stub)
	if !is_stub {
		return
	}
	testing.expect_value(t, hole.hole_type.name, "Fixed")
	testing.expect_value(t, hole.has_fallback, false)
}

@(test)
test_parse_stub_expr_atom_with_fallback :: proc(t: ^testing.T) {
	source := "let SPEED: Fixed = @stub(Fixed, 1.5)\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.lets), 1)
	hole, is_stub := ast.lets[0].value.(^Stub_Expr)
	testing.expect(t, is_stub)
	if !is_stub {
		return
	}
	testing.expect_value(t, hole.hole_type.name, "Fixed")
	testing.expect_value(t, hole.has_fallback, true)
	_, fallback_is_fixed := hole.fallback.(^Fixed_Lit_Expr)
	testing.expect(t, fallback_is_fixed)
}

@(test)
test_parse_stub_expr_atom_nested_positions :: proc(t: ^testing.T) {
	source := "fn place() -> Vec2 {\n  return Vec2{x: @stub(Fixed), y: @stub(Fixed, 1.0)}\n}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	ret, is_return := ast.fns[0].body[0].(Return_Node)
	testing.expect(t, is_return)
	if !is_return {
		return
	}
	record, is_record := ret.value.(^Record_Expr)
	testing.expect(t, is_record)
	if !is_record {
		return
	}
	testing.expect_value(t, len(record.fields), 2)
	x_hole, x_is_stub := record.fields[0].value.(^Stub_Expr)
	testing.expect(t, x_is_stub)
	if x_is_stub {
		testing.expect_value(t, x_hole.has_fallback, false)
	}
	y_hole, y_is_stub := record.fields[1].value.(^Stub_Expr)
	testing.expect(t, y_is_stub)
	if y_is_stub {
		testing.expect_value(t, y_hole.has_fallback, true)
	}
}

@(test)
test_parse_stub_expr_atom_in_call_args :: proc(t: ^testing.T) {
	source := "fn capped(limit: Fixed) -> Fixed {\n  return clamp(@stub(Fixed, 0.5), limit)\n}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	ret, is_return := ast.fns[0].body[0].(Return_Node)
	testing.expect(t, is_return)
	if !is_return {
		return
	}
	call, is_call := ret.value.(^Call_Expr)
	testing.expect(t, is_call)
	if !is_call {
		return
	}
	testing.expect_value(t, len(call.args), 2)
	_, arg_is_stub := call.args[0].(^Stub_Expr)
	testing.expect(t, arg_is_stub)
}

@(test)
test_parse_non_stub_directive_in_expression_rejected :: proc(t: ^testing.T) {
	source := "fn boost() -> Fixed {\n  return @doc(\"not a value\")\n}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_stub_expr_missing_type_rejected :: proc(t: ^testing.T) {
	source := "fn boost() -> Fixed {\n  return @stub()\n}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_stub_expr_missing_separator_rejected :: proc(t: ^testing.T) {
	source := "fn boost() -> Fixed {\n  return @stub(Fixed 1.0)\n}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_pipeline_ordered_named_stages :: proc(t: ^testing.T) {
	source := "pipeline Pong {\n" +
		"  startup:   [setup]\n" +
		"  control:   [paddle_move, ball_move]\n" +
		"  scoring:   [score, tally, serve]\n" +
		"  render:    [draw_paddle, draw_ball, draw_score]\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.pipelines), 1)
	pl := ast.pipelines[0]
	testing.expect_value(t, pl.name, "Pong")
	testing.expect_value(t, len(pl.stages), 4)
	testing.expect_value(t, pl.stages[0].name, "startup")
	testing.expect_value(t, len(pl.stages[0].behaviors), 1)
	testing.expect_value(t, pl.stages[1].name, "control")
	testing.expect_value(t, len(pl.stages[1].behaviors), 2)
	testing.expect_value(t, pl.stages[2].behaviors[1], "tally")
	testing.expect_value(t, pl.stages[3].name, "render")
	testing.expect_value(t, len(pl.stages[3].behaviors), 3)
}

@(test)
test_parse_pipeline_bare_battery_stage :: proc(t: ^testing.T) {
	source := "pipeline Yard {\n" +
		"  control:  [drive]\n" +
		"  physics:  solve\n" +
		"  delivery: [deliver, tally]\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.pipelines), 1)
	pl := ast.pipelines[0]
	testing.expect_value(t, len(pl.stages), 3)
	testing.expect_value(t, pl.stages[0].name, "control")
	testing.expect(t, !pl.stages[0].is_battery)
	testing.expect_value(t, len(pl.stages[0].behaviors), 1)
	battery := pl.stages[1]
	testing.expect_value(t, battery.name, "physics")
	testing.expect(t, battery.is_battery)
	testing.expect_value(t, battery.battery, "solve")
	testing.expect_value(t, len(battery.behaviors), 0)
	testing.expect_value(t, pl.stages[2].name, "delivery")
	testing.expect(t, !pl.stages[2].is_battery)
	testing.expect_value(t, len(pl.stages[2].behaviors), 2)
}

@(test)
test_parse_pipeline_battery_wrong_case_rejected :: proc(t: ^testing.T) {
	_, err := stage_parse(stage_lex("pipeline Yard {\n  physics: Solve\n}\n"))
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_fn_tuple_of_command_lists_return_type :: proc(t: ^testing.T) {
	source := "fn step(self: Crate, pads: [Trigger]) -> ([Despawn], [Delivered]) {\n" +
		"  return ([Despawn()], [Delivered{}])\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	rt := f.return_type
	testing.expect_value(t, rt.name, "()")
	testing.expect_value(t, len(rt.args), 2)
	testing.expect_value(t, rt.args[0].name, "[]")
	testing.expect_value(t, len(rt.args[0].args), 1)
	testing.expect_value(t, rt.args[0].args[0].name, "Despawn")
	testing.expect_value(t, rt.args[1].name, "[]")
	testing.expect_value(t, rt.args[1].args[0].name, "Delivered")
	ret, is_return := f.body[0].(Return_Node)
	testing.expect(t, is_return)
	if is_return {
		tuple, is_tuple := ret.value.(^Tuple_Expr)
		testing.expect(t, is_tuple)
		if is_tuple {
			testing.expect_value(t, len(tuple.elements), 2)
			_, first_is_list := tuple.elements[0].(^List_Expr)
			testing.expect(t, first_is_list)
			_, second_is_list := tuple.elements[1].(^List_Expr)
			testing.expect(t, second_is_list)
		}
	}
}

@(test)
test_parse_gtag_directive_retained :: proc(t: ^testing.T) {
	source := "@doc(\"a ball\")\n" +
		"@gtag(\"ball\", \"score\")\n" +
		"thing Ball { pos: Vec2, vel: Vec2 }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, ast.things[0].doc, "a ball")
	testing.expect_value(t, len(ast.things[0].gtags), 2)
	testing.expect_value(t, ast.things[0].gtags[0], "ball")
	testing.expect_value(t, ast.things[0].gtags[1], "score")
}

@(test)
test_parse_expose_on_fn :: proc(t: ^testing.T) {
	source := "@doc(\"the package's public API\")\n" +
		"@expose\n" +
		"fn axial_to_pixel(cell: Int, size: Fixed) -> Fixed {\n" +
		"  return size\n" +
		"}\n" +
		"\n" +
		"fn cube_round(x: Fixed) -> Fixed {\n" +
		"  return x\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.fns), 2)
	testing.expect_value(t, ast.fns[0].doc, "the package's public API")
	testing.expect(t, ast.fns[0].exposed)
	testing.expect(t, !ast.fns[1].exposed)
}

@(test)
test_parse_expose_on_every_declaration_form :: proc(t: ^testing.T) {
	source := "@expose\nthing Ball { pos: Vec2 }\n" +
		"@expose\ndata Hex { q: Int, r: Int }\n" +
		"@expose\nsignal Hit { side: Int }\n" +
		"@expose\nenum Side { Left, Right }\n" +
		"@expose\nlet LIMIT: Int = 3\n" +
		"@expose\nextern fn arena_count() -> Int\n" +
		"@expose\nquery hex_count(q: Int) -> Int {\n" +
		"  return q\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect(t, ast.things[0].exposed)
	testing.expect(t, ast.datas[0].exposed)
	testing.expect(t, ast.signals[0].exposed)
	testing.expect(t, ast.enums[0].exposed)
	testing.expect(t, ast.lets[0].exposed)
	testing.expect(t, ast.fns[0].exposed)
	testing.expect(t, ast.queries[0].exposed)
}

@(test)
test_parse_expose_accumulates_with_directive_block :: proc(t: ^testing.T) {
	source := "@gtag(\"grid\")\n" +
		"@expose\n" +
		"@doc(\"axial coords\")\n" +
		"@expose\n" +
		"data Hex { q: Int, r: Int }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	d := ast.datas[0]
	testing.expect_value(t, d.doc, "axial coords")
	testing.expect_value(t, len(d.gtags), 1)
	testing.expect(t, d.exposed)
}

@(test)
test_parse_expose_does_not_leak_to_next_declaration :: proc(t: ^testing.T) {
	source := "@expose\n" +
		"fn shown() -> Int {\n" +
		"  return 1\n" +
		"}\n" +
		"\n" +
		"data Hidden { q: Int }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect(t, ast.fns[0].exposed)
	testing.expect(t, !ast.datas[0].exposed)
}

@(test)
test_parse_expose_with_arg_rejected :: proc(t: ^testing.T) {
	source := "@expose(\"api\")\n" +
		"fn shown() -> Int {\n" +
		"  return 1\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Expose_Unexpected_Arg)
}

@(test)
test_parse_break_probe_on_behavior :: proc(t: ^testing.T) {
	source := "@break(self.pos.x > 70.0)\n" +
		"behavior move on Ball {\n" +
		"  fn step(self: Ball) -> Ball {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.behaviors[0].probes), 1)
	probe := ast.behaviors[0].probes[0]
	testing.expect_value(t, probe.kind, Debug_Probe_Kind.Break)
	testing.expect_value(t, probe.line, 1)
	_, is_binary := probe.arg.(^Binary_Expr)
	testing.expect(t, is_binary)
}

@(test)
test_parse_log_probe_on_behavior :: proc(t: ^testing.T) {
	source := "@log(self.head)\n" +
		"behavior crawl on Snake {\n" +
		"  fn step(self: Snake) -> Snake {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.behaviors[0].probes), 1)
	probe := ast.behaviors[0].probes[0]
	testing.expect_value(t, probe.kind, Debug_Probe_Kind.Log)
	_, is_member := probe.arg.(^Member_Expr)
	testing.expect(t, is_member)
}

@(test)
test_parse_watch_probe_on_behavior :: proc(t: ^testing.T) {
	source := "@watch(self.score)\n" +
		"behavior tally on Scoreboard {\n" +
		"  fn step(self: Scoreboard) -> Scoreboard {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.behaviors[0].probes), 1)
	probe := ast.behaviors[0].probes[0]
	testing.expect_value(t, probe.kind, Debug_Probe_Kind.Watch)
	_, is_member := probe.arg.(^Member_Expr)
	testing.expect(t, is_member)
}

@(test)
test_parse_trace_probe_on_pipeline :: proc(t: ^testing.T) {
	source := "@trace\n" +
		"pipeline Game {\n" +
		"  update: [move]\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.pipelines[0].probes), 1)
	probe := ast.pipelines[0].probes[0]
	testing.expect_value(t, probe.kind, Debug_Probe_Kind.Trace)
	testing.expect(t, probe.arg == nil)
}

@(test)
test_parse_probes_accumulate_with_doc_and_gtag :: proc(t: ^testing.T) {
	source := "@doc(\"the ball mover\")\n" +
		"@gtag(\"ball\")\n" +
		"@log(self.pos)\n" +
		"@trace\n" +
		"behavior move on Ball {\n" +
		"  fn step(self: Ball) -> Ball {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	b := ast.behaviors[0]
	testing.expect_value(t, b.doc, "the ball mover")
	testing.expect_value(t, len(b.gtags), 1)
	testing.expect_value(t, len(b.probes), 2)
	testing.expect_value(t, b.probes[0].kind, Debug_Probe_Kind.Log)
	testing.expect_value(t, b.probes[1].kind, Debug_Probe_Kind.Trace)
}

@(test)
test_parse_break_probe_missing_arg_rejected :: proc(t: ^testing.T) {
	source := "@break\n" +
		"behavior move on Ball {\n" +
		"  fn step(self: Ball) -> Ball {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Probe_Missing_Arg)
}

@(test)
test_parse_log_probe_empty_args_rejected :: proc(t: ^testing.T) {
	source := "@log()\n" +
		"behavior move on Ball {\n" +
		"  fn step(self: Ball) -> Ball {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Probe_Missing_Arg)
}

@(test)
test_parse_watch_probe_missing_arg_rejected :: proc(t: ^testing.T) {
	source := "@watch\n" +
		"data Board { score: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Probe_Missing_Arg)
}

@(test)
test_parse_trace_probe_with_arg_rejected :: proc(t: ^testing.T) {
	source := "@trace(self.pos)\n" +
		"behavior move on Ball {\n" +
		"  fn step(self: Ball) -> Ball {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Probe_Unexpected_Arg)
}

@(test)
test_parse_watch_probe_on_data_field :: proc(t: ^testing.T) {
	source := "data Board {\n" +
		"  @watch(self.score)\n" +
		"  score: Int\n" +
		"  high: Int\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	if err != .None {
		return
	}
	fields := ast.datas[0].fields
	testing.expect_value(t, len(fields), 2)
	testing.expect_value(t, len(fields[0].probes), 1)
	if len(fields[0].probes) == 1 {
		probe := fields[0].probes[0]
		testing.expect_value(t, probe.kind, Debug_Probe_Kind.Watch)
		testing.expect_value(t, probe.line, 2)
		_, is_member := probe.arg.(^Member_Expr)
		testing.expect(t, is_member)
	}
	testing.expect_value(t, len(fields[1].probes), 0)
}

@(test)
test_parse_watch_probe_on_data_field_inline :: proc(t: ^testing.T) {
	source := "data Board { @watch(score) score: Int }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	if err != .None {
		return
	}
	field := ast.datas[0].fields[0]
	testing.expect_value(t, len(field.probes), 1)
	if len(field.probes) == 1 {
		testing.expect_value(t, field.probes[0].kind, Debug_Probe_Kind.Watch)
	}
}

@(test)
test_parse_trace_probe_on_pipeline_stage :: proc(t: ^testing.T) {
	source := "pipeline Game {\n" +
		"  @trace\n" +
		"  control: [move]\n" +
		"  render:  [draw]\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	if err != .None {
		return
	}
	stages := ast.pipelines[0].stages
	testing.expect_value(t, len(stages), 2)
	testing.expect_value(t, stages[0].name, "control")
	testing.expect_value(t, len(stages[0].probes), 1)
	if len(stages[0].probes) == 1 {
		probe := stages[0].probes[0]
		testing.expect_value(t, probe.kind, Debug_Probe_Kind.Trace)
		testing.expect(t, probe.arg == nil)
		testing.expect_value(t, probe.line, 2)
	}
	testing.expect_value(t, len(stages[0].behaviors), 1)
	testing.expect_value(t, len(stages[1].probes), 0)
}

@(test)
test_parse_trace_probe_on_battery_stage :: proc(t: ^testing.T) {
	source := "pipeline Yard {\n" +
		"  @trace\n" +
		"  physics: solve\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	if err != .None {
		return
	}
	stage := ast.pipelines[0].stages[0]
	testing.expect(t, stage.is_battery)
	testing.expect_value(t, stage.battery, "solve")
	testing.expect_value(t, len(stage.probes), 1)
	if len(stage.probes) == 1 {
		testing.expect_value(t, stage.probes[0].kind, Debug_Probe_Kind.Trace)
	}
}

@(test)
test_parse_watch_probe_on_thing_field_rejected :: proc(t: ^testing.T) {
	source := "thing Marker {\n" +
		"  @watch(self.pos)\n" +
		"  pos: Int\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Probe_Wrong_Target)
}

@(test)
test_parse_field_break_probe_rejected :: proc(t: ^testing.T) {
	source := "data Board {\n" +
		"  @break(score > 9)\n" +
		"  score: Int\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Probe_Wrong_Target)
}

@(test)
test_parse_field_watch_dangling_rejected :: proc(t: ^testing.T) {
	source := "data Board {\n" +
		"  score: Int\n" +
		"  @watch(self.score)\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Probe_Wrong_Target)
}

@(test)
test_parse_field_watch_missing_arg_rejected :: proc(t: ^testing.T) {
	source := "data Board {\n" +
		"  @watch\n" +
		"  score: Int\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Probe_Missing_Arg)
}

@(test)
test_parse_stage_watch_probe_rejected :: proc(t: ^testing.T) {
	source := "pipeline Game {\n" +
		"  @watch(self.x)\n" +
		"  control: [move]\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Probe_Wrong_Target)
}

@(test)
test_parse_stage_trace_unexpected_arg_rejected :: proc(t: ^testing.T) {
	source := "pipeline Game {\n" +
		"  @trace(self.x)\n" +
		"  control: [move]\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Probe_Unexpected_Arg)
}

@(test)
test_parse_stage_migrate_rejected :: proc(t: ^testing.T) {
	source := "pipeline Game {\n" +
		"  @migrate(from: \"old\")\n" +
		"  control: [move]\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_todo_all_duration_units :: proc(t: ^testing.T) {
	source := "@todo(\"hours\", 1h)\n" +
		"@todo(\"days\", 30d)\n" +
		"@todo(\"weeks\", 2w)\n" +
		"@todo(\"months\", 3mo)\n" +
		"@todo(\"quarters\", 1q)\n" +
		"@todo(\"years\", 1y)\n" +
		"data Board { score: Int }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	todos := ast.datas[0].todos
	testing.expect_value(t, len(todos), 6)
	units := [6]string{"h", "d", "w", "mo", "q", "y"}
	amounts := [6]i64{1, 30, 2, 3, 1, 1}
	for unit, idx in units {
		testing.expect_value(t, todos[idx].window.form, Todo_Window_Form.Duration)
		testing.expect_value(t, todos[idx].window.unit, unit)
		testing.expect_value(t, todos[idx].window.amount, amounts[idx])
	}
}

@(test)
test_parse_todo_date_window :: proc(t: ^testing.T) {
	source := "@todo(\"ship the tutorial\", 2026-09-01)\n" +
		"thing Ball { pos: Vec2 }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	todos := ast.things[0].todos
	testing.expect_value(t, len(todos), 1)
	testing.expect_value(t, todos[0].message, "ship the tutorial")
	testing.expect_value(t, todos[0].window.form, Todo_Window_Form.Date)
	testing.expect_value(t, todos[0].window.year, i64(2026))
	testing.expect_value(t, todos[0].window.month, i64(9))
	testing.expect_value(t, todos[0].window.day, i64(1))
}

@(test)
test_parse_todo_build_count_window :: proc(t: ^testing.T) {
	source := "@todo(\"rebalance\", 50builds)\n" +
		"fn tick(n: Int) -> Int {\n" +
		"  return n\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	todos := ast.fns[0].todos
	testing.expect_value(t, len(todos), 1)
	testing.expect_value(t, todos[0].window.form, Todo_Window_Form.Build_Count)
	testing.expect_value(t, todos[0].window.amount, i64(50))
}

@(test)
test_parse_todo_task_ref_with_doc_and_gtag :: proc(t: ^testing.T) {
	source := "@doc(\"the ball\")\n" +
		"@gtag(\"ball\")\n" +
		"@todo(\"rebalance drops\", T-0042)\n" +
		"thing Ball { pos: Vec2 }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	thing := ast.things[0]
	testing.expect_value(t, thing.doc, "the ball")
	testing.expect_value(t, len(thing.gtags), 1)
	testing.expect_value(t, len(thing.todos), 1)
	todo := thing.todos[0]
	testing.expect_value(t, todo.message, "rebalance drops")
	testing.expect_value(t, todo.window.form, Todo_Window_Form.Task_Ref)
	testing.expect_value(t, todo.window.task, "0042")
	testing.expect_value(t, todo.line, 3)
}

@(test)
test_parse_todo_multiple_accumulate :: proc(t: ^testing.T) {
	source := "@todo(\"first\", 30d)\n" +
		"@todo(\"second\", T-7)\n" +
		"behavior move on Ball {\n" +
		"  fn step(self: Ball) -> Ball {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	todos := ast.behaviors[0].todos
	testing.expect_value(t, len(todos), 2)
	testing.expect_value(t, todos[0].message, "first")
	testing.expect_value(t, todos[0].window.form, Todo_Window_Form.Duration)
	testing.expect_value(t, todos[1].message, "second")
	testing.expect_value(t, todos[1].window.form, Todo_Window_Form.Task_Ref)
}

@(test)
test_parse_todo_unknown_unit_rejected :: proc(t: ^testing.T) {
	source := "@todo(\"m\", 30x)\n" +
		"data Board { score: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Todo_Window)
}

@(test)
test_parse_todo_missing_window_rejected :: proc(t: ^testing.T) {
	source := "@todo(\"m\")\n" +
		"data Board { score: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Todo_Window)
}

@(test)
test_parse_todo_bad_date_shape_rejected :: proc(t: ^testing.T) {
	source := "@todo(\"m\", 2026-9-01)\n" +
		"data Board { score: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Todo_Window)
}

@(test)
test_parse_todo_month_out_of_range_rejected :: proc(t: ^testing.T) {
	source := "@todo(\"m\", 2026-13-01)\n" +
		"data Board { score: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Todo_Window)
}

@(test)
test_parse_todo_bare_count_rejected :: proc(t: ^testing.T) {
	source := "@todo(\"m\", 30)\n" +
		"data Board { score: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Todo_Window)
}

@(test)
test_parse_todo_lowercase_task_ref_rejected :: proc(t: ^testing.T) {
	source := "@todo(\"m\", t-0042)\n" +
		"data Board { score: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Todo_Window)
}

@(test)
test_parse_todo_quoted_window_rejected :: proc(t: ^testing.T) {
	source := "@todo(\"m\", \"30d\")\n" +
		"data Board { score: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Todo_Window)
}

@(test)
test_parse_list_newline_separated_elements :: proc(t: ^testing.T) {
	source := "fn setup() -> [Spawn] {\n" +
		"  return [\n" +
		"    Spawn( Ball{pos: Vec2{x: 80.0, y: 60.0}, vel: Vec2{x: 70.0, y: 40.0}} )\n" +
		"    Spawn( Scoreboard{left: 0, right: 0} )\n" +
		"  ]\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	ret, is_return := f.body[0].(Return_Node)
	testing.expect(t, is_return)
	if is_return {
		list, is_list := ret.value.(^List_Expr)
		testing.expect(t, is_list)
		if is_list {
			testing.expect_value(t, len(list.elements), 2)
			_, first_is_call := list.elements[0].(^Call_Expr)
			testing.expect(t, first_is_call)
		}
	}
}

@(test)
test_parse_fn_tuple_return_type :: proc(t: ^testing.T) {
	source := "fn setup(rng: Rng) -> (Rng, [Spawn]) {\n" +
		"  return (rng, [])\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	testing.expect_value(t, f.return_type.name, "()")
	testing.expect_value(t, len(f.return_type.args), 2)
	testing.expect_value(t, f.return_type.args[0].name, "Rng")
	testing.expect_value(t, f.return_type.args[1].name, "[]")
	testing.expect_value(t, f.return_type.args[1].args[0].name, "Spawn")
}

@(test)
test_parse_nested_tuple_return_type :: proc(t: ^testing.T) {
	source := "fn step(rng: Rng) -> (Rng, (Food, Snake)) {\n" +
		"  return rng\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	testing.expect_value(t, f.return_type.name, "()")
	testing.expect_value(t, len(f.return_type.args), 2)
	testing.expect_value(t, f.return_type.args[1].name, "()")
	testing.expect_value(t, len(f.return_type.args[1].args), 2)
	testing.expect_value(t, f.return_type.args[1].args[0].name, "Food")
	testing.expect_value(t, f.return_type.args[1].args[1].name, "Snake")
}

@(test)
test_parse_variant_in_if_condition_leaves_guard_brace :: proc(t: ^testing.T) {
	source := "fn turn(current: Dir) -> Dir {\n" +
		"  if current != Dir::Down { return Dir::Up }\n" +
		"  return current\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	guard, is_if := f.body[0].(If_Node)
	testing.expect(t, is_if)
	if is_if {
		cond, is_binary := guard.cond.(^Binary_Expr)
		testing.expect(t, is_binary)
		if is_binary {
			rhs, is_variant := cond.rhs.(^Variant_Expr)
			testing.expect(t, is_variant)
			if is_variant {
				testing.expect_value(t, rhs.variant, "Down")
				testing.expect(t, !rhs.has_fields)
			}
		}
		testing.expect_value(t, len(guard.body), 1)
		_, body_is_return := guard.body[0].(Return_Node)
		testing.expect(t, body_is_return)
	}
}

@(test)
test_parse_variant_in_match_scrutinee_leaves_block_brace :: proc(t: ^testing.T) {
	source := "fn pick(x: Dir) -> Bool {\n" +
		"  return match x == Dir::Up {\n" +
		"    Bool::True => true\n" +
		"    Bool::False => false\n" +
		"  }\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
}

@(test)
test_parse_migrate_rename_field :: proc(t: ^testing.T) {
	source := "data Player {\n" +
		"  @migrate(from: \"old_pos\")\n" +
		"  pos: Int\n" +
		"  hp: Int\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	fields := ast.datas[0].fields
	testing.expect_value(t, len(fields), 2)
	testing.expect(t, fields[0].has_migrate)
	testing.expect(t, fields[0].migrate.has_from)
	testing.expect_value(t, fields[0].migrate.from, "old_pos")
	testing.expect(t, !fields[0].migrate.has_with)
	testing.expect_value(t, fields[0].migrate.line, 2)
	testing.expect(t, !fields[1].has_migrate)
}

@(test)
test_parse_migrate_retype_field_inline :: proc(t: ^testing.T) {
	source := "data Player { @migrate(with: meters_to_units) pos: Fixed }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	field := ast.datas[0].fields[0]
	testing.expect(t, field.has_migrate)
	testing.expect(t, !field.migrate.has_from)
	testing.expect(t, field.migrate.has_with)
	testing.expect_value(t, field.migrate.with, "meters_to_units")
}

@(test)
test_parse_migrate_rename_retype_field :: proc(t: ^testing.T) {
	source := "data Player {\n" +
		"  @migrate(from: \"speed\", with: to_velocity)\n" +
		"  vel: Fixed\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	field := ast.datas[0].fields[0]
	testing.expect(t, field.has_migrate)
	testing.expect_value(t, field.migrate.from, "speed")
	testing.expect_value(t, field.migrate.with, "to_velocity")
}

@(test)
test_parse_migrate_renamed_type_decl :: proc(t: ^testing.T) {
	source := "@doc(\"the player\")\n" +
		"@migrate(from: \"OldPlayer\")\n" +
		"data Player { hp: Int }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	decl := ast.datas[0]
	testing.expect_value(t, decl.doc, "the player")
	testing.expect(t, decl.has_migrate)
	testing.expect(t, decl.migrate.has_from)
	testing.expect_value(t, decl.migrate.from, "OldPlayer")
	testing.expect(t, !decl.migrate.has_with)
	testing.expect_value(t, decl.migrate.line, 2)
}

@(test)
test_parse_migrate_with_before_from_rejected :: proc(t: ^testing.T) {
	source := "data Player { @migrate(with: lift, from: \"old\") hp: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Migrate)
}

@(test)
test_parse_migrate_empty_args_rejected :: proc(t: ^testing.T) {
	source := "data Player { @migrate() hp: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Migrate)
}

@(test)
test_parse_migrate_missing_args_rejected :: proc(t: ^testing.T) {
	source := "data Player { @migrate hp: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Migrate)
}

@(test)
test_parse_migrate_unquoted_from_rejected :: proc(t: ^testing.T) {
	source := "data Player { @migrate(from: old_pos) pos: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Migrate)
}

@(test)
test_parse_migrate_empty_from_rejected :: proc(t: ^testing.T) {
	source := "data Player { @migrate(from: \"\") pos: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Migrate)
}

@(test)
test_parse_migrate_unknown_key_rejected :: proc(t: ^testing.T) {
	source := "data Player { @migrate(to: \"new_pos\") pos: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Migrate)
}

@(test)
test_parse_migrate_duplicate_from_rejected :: proc(t: ^testing.T) {
	source := "data Player { @migrate(from: \"a\", from: \"b\") pos: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Migrate)
}

@(test)
test_parse_migrate_wrong_case_convert_rejected :: proc(t: ^testing.T) {
	source := "data Player { @migrate(with: Lift) pos: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_migrate_on_thing_field_rejected :: proc(t: ^testing.T) {
	source := "thing Ball { @migrate(from: \"p\") pos: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Migrate_Wrong_Target)
}

@(test)
test_parse_migrate_on_signal_field_rejected :: proc(t: ^testing.T) {
	source := "signal Goal { @migrate(from: \"s\") side: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Migrate_Wrong_Target)
}

@(test)
test_parse_migrate_prefix_non_data_decl_rejected :: proc(t: ^testing.T) {
	source := "@migrate(from: \"OldColor\")\n" +
		"enum Color { Red, Blue }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Migrate_Wrong_Target)
}

@(test)
test_parse_migrate_decl_level_retype_rejected :: proc(t: ^testing.T) {
	source := "@migrate(with: lift)\n" +
		"data Player { hp: Int }\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Migrate_Wrong_Target)
}

@(test)
test_parse_migrate_dangling_in_body_rejected :: proc(t: ^testing.T) {
	source := "data Player {\n" +
		"  hp: Int\n" +
		"  @migrate(from: \"old\")\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Migrate_Wrong_Target)
}

@(test)
test_parse_migrate_duplicate_before_field_rejected :: proc(t: ^testing.T) {
	source := "data Player {\n" +
		"  @migrate(from: \"a\")\n" +
		"  @migrate(from: \"b\")\n" +
		"  pos: Int\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Malformed_Migrate)
}

@(test)
test_parse_decl_sequence_source_order :: proc(t: ^testing.T) {
	source := "import assets\n" +
		"fn helper() -> Int {\n  return 1\n}\n" +
		"data Cell { x: Int }\n" +
		"let SIZE: Int = 8\n" +
		"thing Board { c: Cell }\n" +
		"enum Side { Left, Right }\n" +
		"signal Moved {}\n" +
		"query cells() -> [Cell] {\n  return []\n}\n" +
		"behavior hold on Board {\n  fn step(self: Board) -> Board {\n    return self\n  }\n}\n" +
		"pipeline Loop {\n  update: [hold]\n}\n" +
		"data Grid { c: Cell }\n" +
		"test \"t\" {\n  assert SIZE == 8\n}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	expected := [?]Decl_Ref {
		{kind = .Fn, index = 0},
		{kind = .Data, index = 0},
		{kind = .Let, index = 0},
		{kind = .Thing, index = 0},
		{kind = .Enum, index = 0},
		{kind = .Signal, index = 0},
		{kind = .Query, index = 0},
		{kind = .Behavior, index = 0},
		{kind = .Pipeline, index = 0},
		{kind = .Data, index = 1},
		{kind = .Test, index = 0},
	}
	testing.expect_value(t, len(ast.decls), len(expected))
	if len(ast.decls) != len(expected) {
		return
	}
	for ref, i in expected {
		testing.expect_value(t, ast.decls[i], ref)
	}
	testing.expect_value(t, ast.datas[ast.decls[9].index].name, "Grid")
	extern_ast, extern_err := stage_parse(stage_lex("data A { x: Int }\nextern fn arena_spawns() -> Int\n"))
	testing.expect_value(t, extern_err, Parse_Error.None)
	testing.expect_value(t, len(extern_ast.decls), 2)
	if len(extern_ast.decls) == 2 {
		testing.expect_value(t, extern_ast.decls[1], Decl_Ref{kind = .Fn, index = 0})
	}
}

@(test)
test_parse_extern_type_decl :: proc(t: ^testing.T) {
	source := "data A { x: Int }\nextern type Sketch\nextern type Anchors\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.extern_types), 2)
	if len(ast.extern_types) != 2 {
		return
	}
	testing.expect_value(t, ast.extern_types[0].name, "Sketch")
	testing.expect_value(t, ast.extern_types[0].line, 2)
	testing.expect_value(t, ast.extern_types[1].name, "Anchors")
	testing.expect_value(t, len(ast.decls), 3)
	if len(ast.decls) == 3 {
		testing.expect_value(t, ast.decls[1], Decl_Ref{kind = .Extern_Type, index = 0})
		testing.expect_value(t, ast.decls[2], Decl_Ref{kind = .Extern_Type, index = 1})
	}
}

@(test)
test_parse_extern_type_carries_directive_block :: proc(t: ^testing.T) {
	source := "@doc(\"an immutable 2D outline\")\n" +
		"@gtag(\"geometry\")\n" +
		"@expose\n" +
		"extern type Sketch\n" +
		"\n" +
		"extern type Anchors\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.extern_types), 2)
	if len(ast.extern_types) != 2 {
		return
	}
	testing.expect_value(t, ast.extern_types[0].doc, "an immutable 2D outline")
	testing.expect_value(t, len(ast.extern_types[0].gtags), 1)
	testing.expect(t, ast.extern_types[0].exposed)
	testing.expect_value(t, ast.extern_types[1].doc, "")
	testing.expect(t, !ast.extern_types[1].exposed)
}

@(test)
test_parse_extern_type_wrong_case_rejected :: proc(t: ^testing.T) {
	_, err := stage_parse(stage_lex("extern type sketch\n"))
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_extern_family_closed :: proc(t: ^testing.T) {
	_, data_err := stage_parse(stage_lex("extern data Foo { x: Int }\n"))
	testing.expect_value(t, data_err, Parse_Error.Malformed_Extern)
	_, bare_err := stage_parse(stage_lex("extern\n"))
	testing.expect_value(t, bare_err, Parse_Error.Malformed_Extern)
}

@(test)
test_parse_extern_type_trailing_junk_rejected :: proc(t: ^testing.T) {
	_, brace_err := stage_parse(stage_lex("extern type Sketch { x: Int }\n"))
	testing.expect_value(t, brace_err, Parse_Error.Unexpected_Token)
	_, generic_brace_err := stage_parse(stage_lex("extern type View[T] { x: Int }\n"))
	testing.expect_value(t, generic_brace_err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_generic_data_header :: proc(t: ^testing.T) {
	source := "data Ref[T] { id: Id }\ndata Choice[T] { label: String, value: T }\ndata Pair[K, V] { k: K, v: V }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.datas), 3)
	if len(ast.datas) != 3 {
		return
	}
	testing.expect_value(t, ast.datas[0].name, "Ref")
	testing.expect_value(t, len(ast.datas[0].type_params), 1)
	if len(ast.datas[0].type_params) == 1 {
		testing.expect_value(t, ast.datas[0].type_params[0], "T")
	}
	testing.expect_value(t, len(ast.datas[1].fields), 2)
	if len(ast.datas[1].fields) == 2 {
		testing.expect_value(t, ast.datas[1].fields[1].type.name, "T")
	}
	testing.expect_value(t, len(ast.datas[2].type_params), 2)
	if len(ast.datas[2].type_params) == 2 {
		testing.expect_value(t, ast.datas[2].type_params[0], "K")
		testing.expect_value(t, ast.datas[2].type_params[1], "V")
	}
}

@(test)
test_parse_generic_enum_header :: proc(t: ^testing.T) {
	source := "enum Option[T] { Some(T), None }\nenum Result[T, E] { Ok(T), Err(E) }\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.enums), 2)
	if len(ast.enums) != 2 {
		return
	}
	testing.expect_value(t, ast.enums[0].name, "Option")
	testing.expect_value(t, len(ast.enums[0].type_params), 1)
	if len(ast.enums[0].type_params) == 1 {
		testing.expect_value(t, ast.enums[0].type_params[0], "T")
	}
	testing.expect_value(t, len(ast.enums[0].variants), 2)
	if len(ast.enums[0].variants) == 2 {
		testing.expect_value(t, len(ast.enums[0].variants[0].tuple), 1)
		if len(ast.enums[0].variants[0].tuple) == 1 {
			testing.expect_value(t, ast.enums[0].variants[0].tuple[0].name, "T")
		}
	}
	testing.expect_value(t, len(ast.enums[1].type_params), 2)
	if len(ast.enums[1].type_params) == 2 {
		testing.expect_value(t, ast.enums[1].type_params[0], "T")
		testing.expect_value(t, ast.enums[1].type_params[1], "E")
	}
}

@(test)
test_parse_generic_extern_type_header :: proc(t: ^testing.T) {
	source := "extern type View[T]\nextern type Widget[Msg]\nextern type Theme\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.extern_types), 3)
	if len(ast.extern_types) != 3 {
		return
	}
	testing.expect_value(t, ast.extern_types[0].name, "View")
	testing.expect_value(t, len(ast.extern_types[0].type_params), 1)
	if len(ast.extern_types[0].type_params) == 1 {
		testing.expect_value(t, ast.extern_types[0].type_params[0], "T")
	}
	testing.expect_value(t, len(ast.extern_types[1].type_params), 1)
	if len(ast.extern_types[1].type_params) == 1 {
		testing.expect_value(t, ast.extern_types[1].type_params[0], "Msg")
	}
	testing.expect_value(t, len(ast.extern_types[2].type_params), 0)
}

@(test)
test_parse_generic_header_then_kind_order :: proc(t: ^testing.T) {
	ast, err := stage_parse(stage_lex("data Vel[T]: Num { x: T }\n"))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.datas), 1)
	if len(ast.datas) != 1 {
		return
	}
	testing.expect_value(t, len(ast.datas[0].type_params), 1)
	testing.expect_value(t, ast.datas[0].kind, "Num")
}

@(test)
test_parse_generic_header_closed_decl_kinds :: proc(t: ^testing.T) {
	_, thing_err := stage_parse(stage_lex("thing Foo[T] { x: Int }\n"))
	testing.expect_value(t, thing_err, Parse_Error.Unexpected_Token)
	_, signal_err := stage_parse(stage_lex("signal Hit[T] { amount: T }\n"))
	testing.expect_value(t, signal_err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_malformed_type_params_rejected :: proc(t: ^testing.T) {
	_, empty_err := stage_parse(stage_lex("enum Option[] { None }\n"))
	testing.expect_value(t, empty_err, Parse_Error.Malformed_Type_Params)
	_, trailing_err := stage_parse(stage_lex("data Ref[T,] { id: Id }\n"))
	testing.expect_value(t, trailing_err, Parse_Error.Malformed_Type_Params)
	_, missing_comma_err := stage_parse(stage_lex("data Pair[K V] { k: K }\n"))
	testing.expect_value(t, missing_comma_err, Parse_Error.Malformed_Type_Params)
	_, number_err := stage_parse(stage_lex("extern type View[1]\n"))
	testing.expect_value(t, number_err, Parse_Error.Malformed_Type_Params)
	_, unclosed_err := stage_parse(stage_lex("extern type View[T\n"))
	testing.expect_value(t, unclosed_err, Parse_Error.Malformed_Type_Params)
	_, case_err := stage_parse(stage_lex("enum Option[t] { None }\n"))
	testing.expect_value(t, case_err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_fn_type_param :: proc(t: ^testing.T) {
	source := "extern fn find(self: [T], pred: fn(T) -> Bool) -> Option[T]\nextern fn fold(self: [T], init: A, step: fn(A, T) -> A) -> A\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.fns), 2)
	if len(ast.fns) != 2 {
		return
	}
	pred := ast.fns[0].params[1].type
	testing.expect_value(t, pred.name, "fn")
	testing.expect_value(t, len(pred.args), 2)
	if len(pred.args) == 2 {
		testing.expect_value(t, pred.args[0].name, "T")
		testing.expect_value(t, pred.args[1].name, "Bool")
	}
	step := ast.fns[1].params[2].type
	testing.expect_value(t, step.name, "fn")
	testing.expect_value(t, len(step.args), 3)
	if len(step.args) == 3 {
		testing.expect_value(t, step.args[0].name, "A")
		testing.expect_value(t, step.args[1].name, "T")
		testing.expect_value(t, step.args[2].name, "A")
	}
}

@(test)
test_parse_fn_type_general_type_position :: proc(t: ^testing.T) {
	source := "extern fn thunk(supplier: fn() -> Int) -> Int\nextern fn make() -> fn(Int) -> Int\nextern fn pick(opts: Option[fn(T) -> Bool]) -> Bool\nextern fn many(steps: [fn(Int) -> Int]) -> Int\nextern fn curry(f: fn(Int) -> fn(Int) -> Int) -> Int\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.fns), 5)
	if len(ast.fns) != 5 {
		return
	}
	thunk := ast.fns[0].params[0].type
	testing.expect_value(t, thunk.name, "fn")
	testing.expect_value(t, len(thunk.args), 1)
	testing.expect_value(t, ast.fns[1].return_type.name, "fn")
	testing.expect_value(t, ast.fns[2].params[0].type.name, "Option")
	testing.expect_value(t, ast.fns[2].params[0].type.args[0].name, "fn")
	testing.expect_value(t, ast.fns[3].params[0].type.name, "[]")
	testing.expect_value(t, ast.fns[3].params[0].type.args[0].name, "fn")
	curry := ast.fns[4].params[0].type
	testing.expect_value(t, curry.name, "fn")
	testing.expect_value(t, len(curry.args), 2)
	if len(curry.args) == 2 {
		testing.expect_value(t, curry.args[1].name, "fn")
	}
}

@(test)
test_parse_malformed_fn_type_rejected :: proc(t: ^testing.T) {
	_, no_parens_err := stage_parse(stage_lex("extern fn f(g: fn Int -> Int) -> Int\n"))
	testing.expect_value(t, no_parens_err, Parse_Error.Malformed_Fn_Type)
	_, no_arrow_err := stage_parse(stage_lex("extern fn f(g: fn(Int) Int) -> Int\n"))
	testing.expect_value(t, no_arrow_err, Parse_Error.Malformed_Fn_Type)
	_, trailing_err := stage_parse(stage_lex("extern fn f(g: fn(Int,) -> Int) -> Int\n"))
	testing.expect_value(t, trailing_err, Parse_Error.Malformed_Fn_Type)
	_, missing_comma_err := stage_parse(stage_lex("extern fn f(g: fn(Int Int) -> Int) -> Int\n"))
	testing.expect_value(t, missing_comma_err, Parse_Error.Malformed_Fn_Type)
	_, unclosed_err := stage_parse(stage_lex("extern fn f(g: fn(Int -> Int) -> Int\n"))
	testing.expect_value(t, unclosed_err, Parse_Error.Malformed_Fn_Type)
	_, case_err := stage_parse(stage_lex("extern fn f(g: fn(int) -> Int) -> Int\n"))
	testing.expect_value(t, case_err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_fn_keyword_param_name_rejected :: proc(t: ^testing.T) {
	_, err := stage_parse(stage_lex("extern fn grid_cells(w: Int, h: Int, fn: fn(Int, Int) -> Cell) -> [Cell]\n"))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_string_escapes_carried_raw :: proc(t: ^testing.T) {
	ast, err := stage_parse(stage_lex("@doc(\"Built by interpolation (\\\"{x}\\\"), never +.\")\nlet GREETING: String = \"say \\\"hi\\\" \\{now\\}\"\n"))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.lets), 1)
	testing.expect_value(t, ast.lets[0].doc, `Built by interpolation (\"{x}\"), never +.`)
	lit, is_string := ast.lets[0].value.(^String_Lit_Expr)
	testing.expect(t, is_string)
	if is_string {
		testing.expect_value(t, lit.text, `say \"hi\" \{now\}`)
	}
}

@(test)
test_parse_malformed_string_escape_named_verdict :: proc(t: ^testing.T) {
	_, doc_err := stage_parse(stage_lex("@doc(\"a \\n newline\")\nfn f() -> Int {\n  return 1\n}\n"))
	testing.expect_value(t, doc_err, Parse_Error.Malformed_String_Escape)
	_, expr_err := stage_parse(stage_lex("let S: String = \"no \\\\ backslash\"\n"))
	testing.expect_value(t, expr_err, Parse_Error.Malformed_String_Escape)
	_, name_err := stage_parse(stage_lex("test \"bad \\q\" {\n  assert true\n}\n"))
	testing.expect_value(t, name_err, Parse_Error.Malformed_String_Escape)
	_, trailing_err := stage_parse(stage_lex("let S: String = \"dangling\\"))
	testing.expect_value(t, trailing_err, Parse_Error.Malformed_String_Escape)
	_, unterminated_err := stage_parse(stage_lex("let S: String = \"open\n"))
	testing.expect_value(t, unterminated_err, Parse_Error.Unexpected_Token)
}
