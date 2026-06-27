package funpack

import "core:testing"

parse_for_gate :: proc(t: ^testing.T, source: string) -> Ast {
	ast, err := stage_parse(stage_lex(source))
	testing.expect_value(t, err, Parse_Error.None)
	return ast
}

@(test)
test_query_index_gate_exemplar_passes :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"@spatial(Enemy.cell)\n" +
		"query enemies_near(origin: Vec2, r: Fixed) -> [Enemy] {\n" +
		"  return nearest_first(within(all[Enemy], origin, r), origin)\n" +
		"}\n" +
		"@index(Paddle.side)\n" +
		"query paddles_on(side: Side) -> Int {\n" +
		"  return fold(all[Paddle], 0, fn(acc, p) { return acc + 1 })\n" +
		"}\n" +
		"query pure_value(r: Fixed) -> Fixed {\n" +
		"  return r * 0.5\n" +
		"}\n")
	testing.expect_value(t, stage_gates(ast), Gate_Error.None)
}

@(test)
test_query_missing_index_named_verdict :: proc(t: ^testing.T) {
	direct := parse_for_gate(t,
		"query enemies_near(origin: Vec2, r: Fixed) -> [Enemy] {\n" +
		"  return within(all[Enemy], origin, r)\n" +
		"}\n")
	verdict := gate_verdict(direct)
	testing.expect_value(t, verdict.err, Gate_Error.Query_Missing_Index)
	testing.expect_value(t, verdict.declaration, "enemies_near")

	let_traced := parse_for_gate(t,
		"query enemies_near(origin: Vec2, r: Fixed) -> [Enemy] {\n" +
		"  let table = all[Enemy]\n" +
		"  return within(table, origin, r)\n" +
		"}\n")
	testing.expect_value(t, gate_verdict(let_traced).err, Gate_Error.Query_Missing_Index)

	wrong_kind := parse_for_gate(t,
		"@index(Enemy.cell)\n" +
		"query enemies_near(origin: Vec2, r: Fixed) -> [Enemy] {\n" +
		"  return within(all[Enemy], origin, r)\n" +
		"}\n")
	testing.expect_value(t, gate_verdict(wrong_kind).err, Gate_Error.Query_Missing_Index)
}

@(test)
test_query_unused_index_named_verdict :: proc(t: ^testing.T) {
	dead_spatial := parse_for_gate(t,
		"@spatial(Enemy.cell)\n" +
		"query enemy_count() -> Int {\n" +
		"  return fold(all[Enemy], 0, fn(acc, e) { return acc + 1 })\n" +
		"}\n")
	verdict := gate_verdict(dead_spatial)
	testing.expect_value(t, verdict.err, Gate_Error.Query_Unused_Index)
	testing.expect_value(t, verdict.declaration, "enemy_count")

	dead_index := parse_for_gate(t,
		"@index(Crate.cell)\n" +
		"query enemy_count() -> Int {\n" +
		"  return fold(all[Enemy], 0, fn(acc, e) { return acc + 1 })\n" +
		"}\n")
	testing.expect_value(t, gate_verdict(dead_index).err, Gate_Error.Query_Unused_Index)
}

@(test)
test_query_index_gate_rides_the_pipeline :: proc(t: ^testing.T) {
	_, err := run_test_pipeline(
		"import engine.list.within\n" +
		"thing Enemy { cell: Vec2 }\n" +
		"query enemies_near(origin: Vec2, r: Fixed) -> [Enemy] {\n" +
		"  return within(all[Enemy], origin, r)\n" +
		"}\n")
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
}

@(test)
test_query_index_gate_untraceable_collection_stays_permissive :: proc(t: ^testing.T) {
	ast := parse_for_gate(t,
		"@spatial(Enemy.cell)\n" +
		"query enemies_near(candidates: [Enemy], origin: Vec2, r: Fixed) -> [Enemy] {\n" +
		"  return within(candidates, origin, r)\n" +
		"}\n")
	testing.expect_value(t, stage_gates(ast), Gate_Error.None)
}
