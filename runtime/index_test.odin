package funpack_runtime

import "core:testing"

index_blackboard :: proc(pairs: ..struct {
		name:  string,
		value: Field_Value,
	}) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, context.temp_allocator)
	for pair in pairs {
		fields[pair.name] = pair.value
	}
	return fields
}

index_test_version :: proc(thing: string, blackboards: []map[string]Field_Value) -> World_Version {
	rows := make([]Row, len(blackboards), context.temp_allocator)
	for fields, i in blackboards {
		rows[i] = Row{id = Id{raw = Thing_Id(i)}, fields = fields}
	}
	tables := make([]Version_Table, 1, context.temp_allocator)
	tables[0] = Version_Table{thing = thing, singleton = false, rows = rows, next_id = Thing_Id(len(rows))}
	return World_Version{tick = 0, tables = tables}
}

index_test_program :: proc(reqs: []Index_Req) -> Program {
	queries := make([]Query_Decl, 1, context.temp_allocator)
	queries[0] = Query_Decl{name = "probe", indexes = reqs}
	return Program{queries = queries}
}

@(test)
test_index_reqs_dedupe_first_declaration_order :: proc(t: ^testing.T) {
	queries := make([]Query_Decl, 2, context.temp_allocator)
	queries[0] = Query_Decl {
		name    = "near",
		indexes = []Index_Req{{kind = .Spatial, thing = "Ball", field = "pos"}, {kind = .Index, thing = "Paddle", field = "side"}},
	}
	queries[1] = Query_Decl {
		name    = "keyed",
		indexes = []Index_Req{{kind = .Index, thing = "Paddle", field = "side"}, {kind = .Index, thing = "Ball", field = "pos"}},
	}
	program := Program{queries = queries}
	reqs := program_index_reqs(&program, context.temp_allocator)
	testing.expect_value(t, len(reqs), 3)
	testing.expect_value(t, reqs[0], Index_Req{kind = .Spatial, thing = "Ball", field = "pos"})
	testing.expect_value(t, reqs[1], Index_Req{kind = .Index, thing = "Paddle", field = "side"})
	testing.expect_value(t, reqs[2], Index_Req{kind = .Index, thing = "Ball", field = "pos"})
}

@(test)
test_index_build_defined_key_then_id_order :: proc(t: ^testing.T) {
	version := index_test_version("Paddle", {
		index_blackboard({"side", string("Side::Right")}),
		index_blackboard({"side", string("Side::Left")}),
		index_blackboard({"side", string("Side::Left")}),
	})
	program := index_test_program([]Index_Req{{kind = .Index, thing = "Paddle", field = "side"}})
	state := build_index_state(&program, &version, context.temp_allocator)
	testing.expect_value(t, len(state.tables), 1)
	table := state.tables[0]
	testing.expect_value(t, table.supported, true)
	testing.expect_value(t, len(table.entries), 3)
	testing.expect_value(t, table.entries[0].id.raw, Thing_Id(1))
	testing.expect_value(t, table.entries[1].id.raw, Thing_Id(2))
	testing.expect_value(t, table.entries[2].id.raw, Thing_Id(0))
}

@(test)
test_index_numeric_keys_order_numerically :: proc(t: ^testing.T) {
	version := index_test_version("Probe", {
		index_blackboard({"n", i64(5)}),
		index_blackboard({"n", i64(-3)}),
		index_blackboard({"n", i64(0)}),
	})
	program := index_test_program([]Index_Req{{kind = .Index, thing = "Probe", field = "n"}})
	state := build_index_state(&program, &version, context.temp_allocator)
	table := state.tables[0]
	testing.expect_value(t, table.entries[0].id.raw, Thing_Id(1))
	testing.expect_value(t, table.entries[1].id.raw, Thing_Id(2))
	testing.expect_value(t, table.entries[2].id.raw, Thing_Id(0))
}

@(test)
test_index_lookup_answers_ascending_ids_and_fails_closed :: proc(t: ^testing.T) {
	version := index_test_version("Paddle", {
		index_blackboard({"side", string("Side::Left")}),
		index_blackboard({"side", string("Side::Right")}),
		index_blackboard({"side", string("Side::Left")}),
	})
	program := index_test_program([]Index_Req{{kind = .Index, thing = "Paddle", field = "side"}})
	state := build_index_state(&program, &version, context.temp_allocator)

	ids, ok := index_lookup(&state, "Paddle", "side", Field_Value(string("Side::Left")), context.temp_allocator)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, len(ids), 2)
	testing.expect_value(t, ids[0].raw, Thing_Id(0))
	testing.expect_value(t, ids[1].raw, Thing_Id(2))

	empty, empty_ok := index_lookup(&state, "Paddle", "side", Field_Value(string("Side::Up")), context.temp_allocator)
	testing.expect_value(t, empty_ok, true)
	testing.expect_value(t, len(empty), 0)

	_, undeclared_ok := index_lookup(&state, "Ball", "pos", Field_Value(string("Side::Left")), context.temp_allocator)
	testing.expect_value(t, undeclared_ok, false)
}

@(test)
test_index_fold_equals_rebuild_and_shares_unchanged :: proc(t: ^testing.T) {
	ball_rows := make([]Row, 1, context.temp_allocator)
	ball_rows[0] = Row{id = Id{raw = 0}, fields = index_blackboard({"pos", Vec2{to_fixed(1), to_fixed(2)}})}
	paddle_rows := make([]Row, 1, context.temp_allocator)
	paddle_rows[0] = Row{id = Id{raw = 0}, fields = index_blackboard({"side", string("Side::Left")})}
	tables := make([]Version_Table, 2, context.temp_allocator)
	tables[0] = Version_Table{thing = "Ball", rows = ball_rows, next_id = 1}
	tables[1] = Version_Table{thing = "Paddle", rows = paddle_rows, next_id = 1}
	prior := World_Version{tick = 0, tables = tables}

	program := index_test_program([]Index_Req{
		{kind = .Spatial, thing = "Ball", field = "pos"},
		{kind = .Index, thing = "Paddle", field = "side"},
	})
	prior_state := build_index_state(&program, &prior, context.temp_allocator)

	moved_rows := make([]Row, 1, context.temp_allocator)
	moved_rows[0] = Row{id = Id{raw = 0}, fields = index_blackboard({"pos", Vec2{to_fixed(7), to_fixed(2)}})}
	changed := make(map[string]Version_Table, context.temp_allocator)
	changed["Ball"] = Version_Table{thing = "Ball", rows = moved_rows, next_id = 1}
	next := commit_version(prior, changed, context.temp_allocator)

	folded := fold_index_state(prior_state, &prior, &next, context.temp_allocator)
	rebuilt := build_index_state(&program, &next, context.temp_allocator)

	testing.expect_value(t, index_states_equal(folded, rebuilt), true)
	testing.expect_value(t, index_state_digest(folded), index_state_digest(rebuilt))
	testing.expect(t, raw_data(folded.tables[1].entries) == raw_data(prior_state.tables[1].entries))
	testing.expect(t, raw_data(folded.tables[0].entries) != raw_data(prior_state.tables[0].entries))
	moved_key, _ := folded.tables[0].entries[0].key.(Vec2)
	testing.expect_value(t, moved_key.x, to_fixed(7))
}

@(test)
test_index_digest_pins_maintained_content :: proc(t: ^testing.T) {
	version := index_test_version("Paddle", {
		index_blackboard({"side", string("Side::Left")}),
		index_blackboard({"side", string("Side::Right")}),
	})
	program := index_test_program([]Index_Req{{kind = .Index, thing = "Paddle", field = "side"}})
	first := build_index_state(&program, &version, context.temp_allocator)
	second := build_index_state(&program, &version, context.temp_allocator)
	testing.expect_value(t, index_state_digest(first), index_state_digest(second))

	moved := index_test_version("Paddle", {
		index_blackboard({"side", string("Side::Left")}),
		index_blackboard({"side", string("Side::Left")}),
	})
	third := build_index_state(&program, &moved, context.temp_allocator)
	testing.expect(t, index_state_digest(first) != index_state_digest(third))
}

@(test)
test_index_unsupported_key_fails_closed :: proc(t: ^testing.T) {
	missing := index_test_version("Paddle", {index_blackboard({"other", i64(1)})})
	program := index_test_program([]Index_Req{{kind = .Index, thing = "Paddle", field = "side"}})
	state := build_index_state(&program, &missing, context.temp_allocator)
	testing.expect_value(t, state.tables[0].supported, false)
	testing.expect_value(t, len(state.tables[0].entries), 0)
	_, ok := index_lookup(&state, "Paddle", "side", Field_Value(string("Side::Left")), context.temp_allocator)
	testing.expect_value(t, ok, false)

	transient := Value(Lambda_Value{})
	boxed := index_test_version("Paddle", {
		index_blackboard({"side", Variant_Value{enum_type = "Side", case_name = "Odd", payload = &transient}}),
	})
	boxed_state := build_index_state(&program, &boxed, context.temp_allocator)
	testing.expect_value(t, boxed_state.tables[0].supported, false)
}

@(test)
test_step_tick_folds_indices_at_commit_boundary :: proc(t: ^testing.T) {
	version := index_test_version("Paddle", {index_blackboard({"side", string("Side::Left")})})
	program := index_test_program([]Index_Req{{kind = .Index, thing = "Paddle", field = "side"}})
	indices := build_index_state(&program, &version, context.temp_allocator)

	next := step_tick(&program, version, Input{}, time_resource(60, context.temp_allocator), context.temp_allocator, nil, &indices)
	rebuilt := build_index_state(&program, &next, context.temp_allocator)
	testing.expect_value(t, index_states_equal(indices, rebuilt), true)
	testing.expect_value(t, index_state_digest(indices), index_state_digest(rebuilt))
}
