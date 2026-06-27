package funpack

import "core:testing"

@(test)
test_parse_all_expr_atom :: proc(t: ^testing.T) {
	source := "query enemy_count() -> Int {\n" +
		"  return len(all[Enemy])\n" +
		"}\n"
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, len(ast.queries), 1)
	if len(ast.queries) != 1 {
		return
	}
	testing.expect_value(t, len(ast.queries[0].body), 1)
}

@(test)
test_parse_all_expr_malformed_tails :: proc(t: ^testing.T) {
	_, lower := stage_parse(stage_lex("query q() -> Int {\n  return len(all[enemy])\n}\n"))
	testing.expect_value(t, lower, Parse_Error.Wrong_Case)
	_, unclosed := stage_parse(stage_lex("query q() -> Int {\n  return len(all[Enemy)\n}\n"))
	testing.expect_value(t, unclosed, Parse_Error.Unexpected_Token)
	_, empty := stage_parse(stage_lex("query q() -> Int {\n  return len(all[])\n}\n"))
	testing.expect_value(t, empty, Parse_Error.Unexpected_Token)
}

@(test)
test_all_name_stays_a_legal_binding :: proc(t: ^testing.T) {
	report, err := run_test_pipeline(
		"test \"all binds as a name\" {\n" +
		"  let all = 2\n" +
		"  assert all + 1 == 3\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_all_outside_query_named_verdict :: proc(t: ^testing.T) {
	ast, parse_err := stage_parse(stage_lex(
		"import engine.list.len\n" +
		"thing Enemy { hp: Fixed }\n" +
		"fn snoop() -> Int {\n" +
		"  return len(all[Enemy])\n" +
		"}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, fn_err := stage_typecheck(ast)
	testing.expect_value(t, fn_err, Type_Error.All_Outside_Query)

	test_ast, test_parse_err := stage_parse(stage_lex(
		"import engine.list.len\n" +
		"thing Enemy { hp: Fixed }\n" +
		"test \"no world read here\" {\n" +
		"  assert len(all[Enemy]) == 0\n" +
		"}\n"))
	testing.expect_value(t, test_parse_err, Parse_Error.None)
	_, test_err := stage_typecheck(test_ast)
	testing.expect_value(t, test_err, Type_Error.All_Outside_Query)
}

@(test)
test_all_unknown_thing_named_verdict :: proc(t: ^testing.T) {
	ast, parse_err := stage_parse(stage_lex(
		"import engine.list.len\n" +
		"query q() -> Int {\n" +
		"  return len(all[Ghost])\n" +
		"}\n"))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, ghost_err := stage_typecheck(ast)
	testing.expect_value(t, ghost_err, Type_Error.All_Unknown_Thing)

	data_ast, data_parse_err := stage_parse(stage_lex(
		"import engine.list.len\n" +
		"data Board { w: Int }\n" +
		"query q() -> Int {\n" +
		"  return len(all[Board])\n" +
		"}\n"))
	testing.expect_value(t, data_parse_err, Parse_Error.None)
	_, data_err := stage_typecheck(data_ast)
	testing.expect_value(t, data_err, Type_Error.All_Unknown_Thing)
}

@(test)
test_all_composes_into_list_combinators :: proc(t: ^testing.T) {
	clean_ast, clean_parse := stage_parse(stage_lex(
		"import engine.list.fold\n" +
		"thing Enemy { hp: Fixed }\n" +
		"query total_hp() -> Fixed {\n" +
		"  return fold(all[Enemy], 0.0, fn(acc, e) { return acc + e.hp })\n" +
		"}\n"))
	testing.expect_value(t, clean_parse, Parse_Error.None)
	_, clean := stage_typecheck(clean_ast)
	testing.expect_value(t, clean, Type_Error.None)

	mismatch_ast, mismatch_parse := stage_parse(stage_lex(
		"import engine.list.fold\n" +
		"thing Enemy { hp: Fixed }\n" +
		"query total_hp() -> Fixed {\n" +
		"  return fold(all[Enemy], 0, fn(acc, e) { return acc + e.hp })\n" +
		"}\n"))
	testing.expect_value(t, mismatch_parse, Parse_Error.None)
	_, mismatch := stage_typecheck(mismatch_ast)
	testing.expect_value(t, mismatch, Type_Error.Type_Mismatch)
}

@(test)
test_all_evaluates_over_setup_seeded_world :: proc(t: ^testing.T) {
	report, err := run_test_pipeline(
		"import engine.world.{Spawn}\n" +
		"import engine.list.fold\n" +
		"thing Enemy { hp: Fixed }\n" +
		"thing Crate { weight: Fixed }\n" +
		"fn setup() -> [Spawn] {\n" +
		"  return [Spawn(Enemy{hp: 3.0}), Spawn(Crate{weight: 9.0}), Spawn(Enemy{hp: 4.0})]\n" +
		"}\n" +
		"query total_hp() -> Fixed {\n" +
		"  return fold(all[Enemy], 0.0, fn(acc, e) { return acc + e.hp })\n" +
		"}\n" +
		"query crate_count() -> Int {\n" +
		"  return fold(all[Crate], 0, fn(acc, c) { return acc + 1 })\n" +
		"}\n" +
		"test \"queries read the startup population\" {\n" +
		"  assert total_hp() == 7.0\n" +
		"  assert crate_count() == 1\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

@(test)
test_all_reads_empty_table_without_setup :: proc(t: ^testing.T) {
	report, err := run_test_pipeline(
		"import engine.list.fold\n" +
		"thing Enemy { hp: Fixed }\n" +
		"query enemy_count() -> Int {\n" +
		"  return fold(all[Enemy], 0, fn(acc, e) { return acc + 1 })\n" +
		"}\n" +
		"test \"empty world reads zero rows\" {\n" +
		"  assert enemy_count() == 0\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_all_row_applies_schema_field_defaults :: proc(t: ^testing.T) {
	report, err := run_test_pipeline(
		"import engine.world.{Spawn}\n" +
		"import engine.list.fold\n" +
		"thing Door { width: Fixed, open_amount: Fixed = 0.5 }\n" +
		"fn setup() -> [Spawn] {\n" +
		"  return [Spawn(Door{width: 2.0})]\n" +
		"}\n" +
		"query total_open() -> Fixed {\n" +
		"  return fold(all[Door], 0.0, fn(acc, d) { return acc + d.open_amount })\n" +
		"}\n" +
		"test \"omitted field reads its default\" {\n" +
		"  assert total_open() == 0.5\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}
