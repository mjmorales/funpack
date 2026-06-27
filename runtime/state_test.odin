package funpack_runtime

import "core:testing"

@(private = "file")
blackboard_with :: proc(pairs: ..struct {
		name:  string,
		value: Field_Value,
	}) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, context.temp_allocator)
	for pair in pairs {
		fields[pair.name] = pair.value
	}
	return fields
}

@(test)
test_view_of_iterates_in_stable_id_order :: proc(t: ^testing.T) {
	view := view_of(
		"Paddle",
		{
			blackboard_with({"score", i64(0)}),
			blackboard_with({"score", i64(1)}),
			blackboard_with({"score", i64(2)}),
		},
		context.temp_allocator,
	)
	testing.expect_value(t, view_count(view), 3)

	for i in 0 ..< view_count(view) {
		row, ok := view_at(view, i)
		testing.expect(t, ok)
		testing.expect_value(t, row.id, Id{raw = Thing_Id(i)})
		score, present := row_field(row, "score")
		testing.expect(t, present)
		testing.expect_value(t, score.(i64), i64(i))
	}

	_, oob := view_at(view, 3)
	testing.expect(t, !oob)
}

@(test)
test_ref_resolves_some_on_live_none_on_absent :: proc(t: ^testing.T) {
	view := view_of(
		"Ball",
		{blackboard_with({"side", "Side::Left"}), blackboard_with({"side", "Side::Right"})},
		context.temp_allocator,
	)

	ref1, ok := view_ref(view, 1)
	testing.expect(t, ok)
	testing.expect_value(t, ref1.thing, "Ball")
	testing.expect_value(t, ref1.id, Id{raw = Thing_Id(1)})

	row, some := view_resolve(view, ref1)
	testing.expect(t, some)
	side, present := row_field(row, "side")
	testing.expect(t, present)
	testing.expect_value(t, side.(string), "Side::Right")

	dangling := Ref{thing = "Ball", id = Id{raw = Thing_Id(99)}}
	_, dangling_some := view_resolve(view, dangling)
	testing.expect(t, !dangling_some)

	wrong_type := Ref{thing = "Paddle", id = Id{raw = Thing_Id(0)}}
	_, wrong_some := view_resolve(view, wrong_type)
	testing.expect(t, !wrong_some)
}

@(test)
test_ref_column_resolves_across_tables :: proc(t: ^testing.T) {
	switches := []Row {
		{id = Id{raw = Thing_Id(0)}, fields = blackboard_with({"open", i64(0)})},
		{id = Id{raw = Thing_Id(1)}, fields = blackboard_with({"open", i64(1)})},
	}
	gate_ref := Ref{thing = "Switch", id = Id{raw = Thing_Id(1)}}
	doors := []Row{{id = Id{raw = Thing_Id(0)}, fields = blackboard_with({"gate", gate_ref})}}

	version := World_Version {
		tick = 0,
		tables = {
			{thing = "Switch", singleton = false, rows = switches, next_id = Thing_Id(2)},
			{thing = "Door", singleton = false, rows = doors, next_id = Thing_Id(1)},
		},
	}

	door_view := view_of_type(&version, "Door")
	door, ok := view_at(door_view, 0)
	testing.expect(t, ok)

	ref, ref_ok := row_ref(door, "gate")
	testing.expect(t, ref_ok)
	switch_row, some := resolve_ref(&version, ref)
	testing.expect(t, some)
	open, present := row_field(switch_row, "open")
	testing.expect(t, present)
	testing.expect_value(t, open.(i64), i64(1))
}

@(test)
test_singleton_exposes_exactly_one_row_by_type :: proc(t: ^testing.T) {
	the_row := Row{id = Id{raw = Thing_Id(0)}, fields = blackboard_with({"phase", "Phase::Day"})}
	version := World_Version {
		tick = 0,
		tables = {
			{thing = "GameState", singleton = true, rows = {the_row}, next_id = Thing_Id(1)},
			{thing = "Empty", singleton = true, rows = nil, next_id = Thing_Id(0)},
		},
	}

	row, ok := singleton_row(&version, "GameState")
	testing.expect(t, ok)
	phase, present := row_field(row, "phase")
	testing.expect(t, present)
	testing.expect_value(t, phase.(string), "Phase::Day")

	_, empty_ok := singleton_row(&version, "Empty")
	testing.expect(t, !empty_ok)

	_, missing_ok := singleton_row(&version, "Nonexistent")
	testing.expect(t, !missing_ok)
}

@(test)
test_ordinary_single_instance_thing_path :: proc(t: ^testing.T) {
	scoreboard := Row {
		id     = Id{raw = Thing_Id(0)},
		fields = blackboard_with({"left", i64(3)}, {"right", i64(5)}),
	}
	version := World_Version {
		tick   = 0,
		tables = {{thing = "Scoreboard", singleton = false, rows = {scoreboard}, next_id = Thing_Id(1)}},
	}

	view := view_of_type(&version, "Scoreboard")
	testing.expect_value(t, view_count(view), 1)
	row, ok := view_at(view, 0)
	testing.expect(t, ok)
	left, l_present := row_field(row, "left")
	right, r_present := row_field(row, "right")
	testing.expect(t, l_present && r_present)
	testing.expect_value(t, left.(i64), i64(3))
	testing.expect_value(t, right.(i64), i64(5))

	_, singleton_ok := singleton_row(&version, "Scoreboard")
	testing.expect(t, !singleton_ok)
}

@(test)
test_cow_commit_shares_and_leaves_prior_readable :: proc(t: ^testing.T) {
	world := load_two_table_world(t)
	defer delete(world.tables)
	base := initial_version(world, context.temp_allocator)

	ball_row := Row{id = Id{raw = Thing_Id(0)}, fields = blackboard_with({"speed", to_fixed(2)})}
	changed := make(map[string]Version_Table, context.temp_allocator)
	changed["Ball"] = Version_Table {
		thing   = "Ball",
		rows    = {ball_row},
		next_id = Thing_Id(1),
	}
	v0 := commit_version(base, changed, context.temp_allocator)
	testing.expect_value(t, v0.tick, 0)

	v0_balls := view_of_type(&v0, "Ball")
	testing.expect_value(t, view_count(v0_balls), 1)
	base_balls := view_of_type(&base, "Ball")
	testing.expect_value(t, view_count(base_balls), 0)

	base_paddle := version_find_table(&base, "Paddle")
	v0_paddle := version_find_table(&v0, "Paddle")
	testing.expect(t, base_paddle != nil && v0_paddle != nil)
	testing.expect_value(t, raw_data(v0_paddle.rows), raw_data(base_paddle.rows))

	paddle_row := Row{id = Id{raw = Thing_Id(0)}, fields = blackboard_with({"y", to_fixed(0)})}
	changed1 := make(map[string]Version_Table, context.temp_allocator)
	changed1["Paddle"] = Version_Table {
		thing   = "Paddle",
		rows    = {paddle_row},
		next_id = Thing_Id(1),
	}
	v1 := commit_version(v0, changed1, context.temp_allocator)
	testing.expect_value(t, v1.tick, 1)

	testing.expect_value(t, view_count(view_of_type(&v1, "Ball")), 1)
	testing.expect_value(t, view_count(view_of_type(&v1, "Paddle")), 1)
	testing.expect_value(t, view_count(view_of_type(&v0, "Paddle")), 0)
}

@(private = "file")
load_two_table_world :: proc(t: ^testing.T) -> World {
	tables := make([]Thing_Table, 2)
	tables[0] = Thing_Table{thing = "Paddle", singleton = false, next_id = Thing_Id(0)}
	tables[1] = Thing_Table{thing = "Ball", singleton = false, next_id = Thing_Id(0)}
	return World{tables = tables}
}

@(test)
test_initial_version_over_golden_world :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	version := initial_version(world, context.temp_allocator)

	testing.expect_value(t, len(version.tables), 3)
	testing.expect_value(t, view_count(view_of_type(&version, "Paddle")), 0)
	testing.expect_value(t, view_count(view_of_type(&version, "Ball")), 0)
	testing.expect_value(t, view_count(view_of_type(&version, "Scoreboard")), 0)

	scoreboard := version_find_table(&version, "Scoreboard")
	testing.expect(t, scoreboard != nil)
	testing.expect(t, !scoreboard.singleton)
}
