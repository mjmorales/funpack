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
test_parse_match_struct_payload_destructure :: proc(t: ^testing.T) {
	// The yard `box_size` shape (spec §02 §5): a struct-payload field-pun arm
	// `Shape2::Box{size} => size` binds the field `size` by name, parallel to
	// the value-side struct-payload Variant_Expr. A wildcard arm follows.
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
	// The field-pun binder is the single field name `size` (binds `size` to the
	// `size` field).
	testing.expect_value(t, len(pat.binders), 1)
	testing.expect_value(t, pat.binders[0], "size")
	testing.expect_value(t, m.arms[1].pattern.kind, Pattern_Kind.Wildcard)
}

@(test)
test_parse_match_struct_payload_multi_field :: proc(t: ^testing.T) {
	// A struct-payload field-pun arm binds every named field, in source order —
	// the binder list pins more than one pun.
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
	// A field-pun binder is a value name — snake_case (spec §02); an UpperCamel
	// field name in the pun position rejects as Wrong_Case.
	_, err := parse_expr_text("match shape { Shape2::Box{Size} => 0, _ => 1 }")
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
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

@(test)
test_parse_data_decl_with_fields :: proc(t: ^testing.T) {
	// `data Name { field: T = default … }` (spec §03 §1): a plain field and
	// a defaulted field, both kept in declaration order.
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
	// The §03/§06 enum-as-role form `enum Steer: Axis { Move }`: a kind
	// ascription after the type name, contextual (Axis is not reserved).
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
	// Plain, tuple-payload, and struct-payload variants in one enum
	// (spec §03 §2).
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
test_parse_thing_and_singleton :: proc(t: ^testing.T) {
	// `thing` and `singleton` share the body grammar; only the is_singleton
	// flag tells them apart (spec §06 §1–2). Scoreboard's Int fields carry
	// `= 0` defaults.
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
	// `signal Name { field: T }` (spec §03 §6, §06 §5).
	ast, err := stage_parse(stage_lex("signal Goal { side: Side }\n"))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.signals), 1)
	testing.expect_value(t, ast.signals[0].name, "Goal")
	testing.expect_value(t, len(ast.signals[0].fields), 1)
	testing.expect_value(t, ast.signals[0].fields[0].type.name, "Side")
}

@(test)
test_parse_module_let_decl :: proc(t: ^testing.T) {
	// A module-level constant `let NAME: T = expr` (spec §02 §6–7), distinct
	// from a test-body let in carrying an explicit type ascription.
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
	// A top-level fn with a multi-statement body — a let then a return —
	// generalizing the single-return lambda the Pratt cascade carries.
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
	// An `if cond { return … }` early-return guard as a statement form in a
	// fn body (spec §02 §5). The condition ends in a field access whose
	// trailing `{` opens the guard block, not a record literal.
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
		// The guard condition is the `at.x < 0.0` comparison, and the guarded
		// body holds the single early return.
		_, cond_is_binary := if_node.cond.(^Binary_Expr)
		testing.expect(t, cond_is_binary)
		testing.expect_value(t, len(if_node.body), 1)
		_, body_is_return := if_node.body[0].(Return_Node)
		testing.expect(t, body_is_return)
	}
}

@(test)
test_parse_behavior_with_reserved_step :: proc(t: ^testing.T) {
	// `behavior name on Thing { fn step(…) -> … { … } }` (spec §06 §3): the
	// reserved `step` entry point, its target, and its read parameters.
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
	// `step` is the built-in, reserved entry point (spec §06 §3); a behavior
	// names no other, so a `fn update(…)` body is rejected at parse.
	source := "behavior bad on Paddle {\n" +
		"  fn update(self: Paddle) -> Paddle {\n" +
		"    return self\n" +
		"  }\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}

@(test)
test_parse_pipeline_ordered_named_stages :: proc(t: ^testing.T) {
	// `pipeline Name { stage: [behaviors] … }` (spec §07 §1): stages keep
	// source order, and each stage value is a behavior-name list.
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
	// Stage order is the contract — the slice preserves source order.
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
	// The yard `physics: solve` shape (spec §07 §1): a stage whose value is a
	// single bare battery name, not a `[behavior, …]` list. The battery stage
	// is_battery is set and its name lives in `battery`; behavior-list stages
	// around it keep the list form. The battery name is recorded as written,
	// not validated here.
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
	// The bordering stages stay behavior-list stages.
	testing.expect_value(t, pl.stages[0].name, "control")
	testing.expect(t, !pl.stages[0].is_battery)
	testing.expect_value(t, len(pl.stages[0].behaviors), 1)
	// The `physics: solve` stage is a single-battery stage.
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
	// A battery name is a value name — snake_case (spec §07); an UpperCamel
	// battery name rejects as Wrong_Case.
	_, err := stage_parse(stage_lex("pipeline Yard {\n  physics: Solve\n}\n"))
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_fn_tuple_of_command_lists_return_type :: proc(t: ^testing.T) {
	// The yard `deliver` return signature (spec §02 §3; §04 §1): a tuple of two
	// list types `([Despawn], [Delivered])`. The tuple is the head "()" with two
	// args, each a list head "[]" whose single arg is the element command type —
	// composing the existing tuple-type and list-type productions, no new
	// grammar. The tuple VALUE `([Despawn()], [Delivered{}])` is two List_Expr.
	source := "fn step(self: Crate, pads: [Trigger]) -> ([Despawn], [Delivered]) {\n" +
		"  return ([Despawn()], [Delivered{}])\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	rt := f.return_type
	testing.expect_value(t, rt.name, "()")
	testing.expect_value(t, len(rt.args), 2)
	// Each tuple element is a list type `[T]` (head "[]") of one command type.
	testing.expect_value(t, rt.args[0].name, "[]")
	testing.expect_value(t, len(rt.args[0].args), 1)
	testing.expect_value(t, rt.args[0].args[0].name, "Despawn")
	testing.expect_value(t, rt.args[1].name, "[]")
	testing.expect_value(t, rt.args[1].args[0].name, "Delivered")
	// The return value is a Tuple_Expr of two List_Expr (both already parse).
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
	// `@gtag("…", …)` is parsed and retained on the declaration it precedes,
	// alongside @doc (spec §05). Multiple labels accumulate.
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
test_parse_list_newline_separated_elements :: proc(t: ^testing.T) {
	// The pong `setup` shape: a multi-line list whose `Spawn(…)` elements are
	// separated by newline alone (no commas). Each element is a call.
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
	// The snake `setup`/`step` return signature (spec §02 §3; §04 §1 — every
	// draw returns `(value, next_rng)`): a tuple type in return position. It is
	// recorded as the head "()" with its positional element Type_Refs as args,
	// mirroring the list head "[]".
	source := "fn setup(rng: Rng) -> (Rng, [Spawn]) {\n" +
		"  return (rng, [])\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	f := ast.fns[0]
	testing.expect_value(t, f.return_type.name, "()")
	testing.expect_value(t, len(f.return_type.args), 2)
	// First element is the bare `Rng`, second is the list `[Spawn]` (head "[]").
	testing.expect_value(t, f.return_type.args[0].name, "Rng")
	testing.expect_value(t, f.return_type.args[1].name, "[]")
	testing.expect_value(t, f.return_type.args[1].args[0].name, "Spawn")
}

@(test)
test_parse_nested_tuple_return_type :: proc(t: ^testing.T) {
	// A tuple element may itself be a tuple — the head recurses by
	// construction, so `(Rng, (A, B))` records a tuple whose second arg is
	// again the head "()".
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
	// The snake `dir_from_input` shape (spec §02 §5): an `if` condition ending in
	// a bare variant comparison (`current != Dir::Down`) must leave the trailing
	// `{` for the guard block, not consume it as a struct-payload variant
	// `Dir::Down{…}`. In the no-struct-literal context an `if`-guard condition
	// shares with a match scrutinee, a `{` after a variant opens the block.
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
		// The condition is the `!=` comparison; its rhs is a BARE variant (no
		// struct payload) — the brace went to the guard block, which holds the
		// return.
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
	// The match-scrutinee analogue: a scrutinee ending in a bare variant compare
	// (`x == Dir::Up`) leaves the `{` for the match block, not a struct payload.
	source := "fn pick(x: Dir) -> Bool {\n" +
		"  return match x == Dir::Up {\n" +
		"    Bool::True => true\n" +
		"    Bool::False => false\n" +
		"  }\n" +
		"}\n"
	_, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
}
