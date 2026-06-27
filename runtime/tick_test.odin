package funpack_runtime

import "core:testing"

@(private = "file")
dt_60hz_value :: proc() -> Fixed {
	return fixed_div(to_fixed(1), to_fixed(60))
}

@(private = "file")
time_resource :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = dt_60hz_value()
	return Record_Value{type_name = "Time", fields = fields}
}

@(private = "file")
startup_version :: proc(program: ^Program, allocator := context.allocator) -> World_Version {
	world := new_world(program^, allocator)
	base := initial_version(world, allocator)
	return run_startup(program, base, allocator)
}

@(test)
test_startup_populates_before_tick_zero :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	base := startup_version(&program, context.temp_allocator)

	testing.expect_value(t, view_count(view_of_type(&base, "Paddle")), 2)
	testing.expect_value(t, view_count(view_of_type(&base, "Ball")), 1)
	testing.expect_value(t, view_count(view_of_type(&base, "Scoreboard")), 1)

	ball, ball_ok := view_at(view_of_type(&base, "Ball"), 0)
	testing.expect(t, ball_ok)
	pos, pos_present := row_field(ball, "pos")
	vel, vel_present := row_field(ball, "vel")
	testing.expect(t, pos_present && vel_present)
	testing.expect_value(t, pos.(Vec2), Vec2{to_fixed(80), to_fixed(60)})
	testing.expect_value(t, vel.(Vec2), Vec2{to_fixed(70), to_fixed(40)})

	scoreboard, sb_ok := view_at(view_of_type(&base, "Scoreboard"), 0)
	testing.expect(t, sb_ok)
	left, l_present := row_field(scoreboard, "left")
	right, r_present := row_field(scoreboard, "right")
	testing.expect(t, l_present && r_present)
	testing.expect_value(t, left.(i64), i64(0))
	testing.expect_value(t, right.(i64), i64(0))
}

@(test)
test_single_tick_advances_ball :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	base := startup_version(&program, context.temp_allocator)
	dt := dt_60hz_value()

	next := step_tick(&program, base, empty(), time_resource(context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, next.tick, base.tick + 1)

	ball, ball_ok := view_at(view_of_type(&next, "Ball"), 0)
	testing.expect(t, ball_ok)
	pos, _ := row_field(ball, "pos")
	want := Vec2 {
		fixed_add(to_fixed(80), fixed_mul(to_fixed(70), dt)),
		fixed_add(to_fixed(60), fixed_mul(to_fixed(40), dt)),
	}
	testing.expect_value(t, pos.(Vec2), want)

	scoreboard, _ := view_at(view_of_type(&next, "Scoreboard"), 0)
	left, _ := row_field(scoreboard, "left")
	right, _ := row_field(scoreboard, "right")
	testing.expect_value(t, left.(i64), i64(0))
	testing.expect_value(t, right.(i64), i64(0))
}

@(test)
test_n_ticks_deterministic :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}

	first := run_n_ticks(&program, 600, empty_input, context.temp_allocator)
	second := run_n_ticks(&program, 600, empty_input, context.temp_allocator)

	testing.expect(t, world_versions_equal(first, second))

	scoreboard, _ := view_at(view_of_type(&first, "Scoreboard"), 0)
	left, _ := row_field(scoreboard, "left")
	right, _ := row_field(scoreboard, "right")
	testing.expect(t, left.(i64) + right.(i64) > 0)
}

@(test)
test_n_ticks_with_input_deterministic :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}

	first := run_n_ticks(&program, 120, hold_p1_up, context.temp_allocator)
	second := run_n_ticks(&program, 120, hold_p1_up, context.temp_allocator)
	testing.expect(t, world_versions_equal(first, second))

	paddle, _ := view_at(view_of_type(&first, "Paddle"), 0)
	y, _ := row_field(paddle, "y")
	testing.expect(t, y.(Fixed) != to_fixed(60))
}

@(private = "file")
Input_Fn :: proc(tick: int, allocator: Runtime_Allocator) -> Input

@(private = "file")
empty_input :: proc(tick: int, allocator: Runtime_Allocator) -> Input {
	context.allocator = allocator
	return empty()
}

@(private = "file")
hold_p1_up :: proc(tick: int, allocator: Runtime_Allocator) -> Input {
	context.allocator = allocator
	return with_value(empty(), .P1, ActionId(0), to_fixed(1))
}

@(private = "file")
run_n_ticks :: proc(
	program: ^Program,
	n: int,
	input_fn: Input_Fn,
	allocator := context.allocator,
) -> World_Version {
	version := startup_version(program, allocator)
	for tick in 0 ..< n {
		snapshot := input_fn(tick, allocator)
		version = step_tick(program, version, snapshot, time_resource(allocator), allocator)
	}
	return version
}

@(test)
test_goal_consumed_same_tick_advances_score :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	base := startup_version(&program, context.temp_allocator)
	scored_setup := place_ball(&program, base, Vec2{to_fixed(200), to_fixed(60)}, Vec2{to_fixed(70), to_fixed(40)})

	next := step_tick(&program, scored_setup, empty(), time_resource(context.temp_allocator), context.temp_allocator)

	scoreboard, _ := view_at(view_of_type(&next, "Scoreboard"), 0)
	left, _ := row_field(scoreboard, "left")
	right, _ := row_field(scoreboard, "right")
	testing.expect_value(t, left.(i64), i64(1))
	testing.expect_value(t, right.(i64), i64(0))

	ball, _ := view_at(view_of_type(&next, "Ball"), 0)
	pos, _ := row_field(ball, "pos")
	vel, _ := row_field(ball, "vel")
	testing.expect_value(t, pos.(Vec2), Vec2{to_fixed(80), to_fixed(60)})
	testing.expect_value(t, vel.(Vec2), Vec2{to_fixed(70), to_fixed(40)})
}

@(private = "file")
place_ball :: proc(
	program: ^Program,
	prior: World_Version,
	pos, vel: Vec2,
	allocator := context.temp_allocator,
) -> World_Version {
	prior_version := prior
	ball, _ := view_at(view_of_type(&prior_version, "Ball"), 0)
	fields := make(map[string]Field_Value, allocator)
	fields["pos"] = pos
	fields["vel"] = vel
	rows := make([]Row, 1, allocator)
	rows[0] = Row{id = ball.id, fields = fields}
	changed := make(map[string]Version_Table, allocator)
	changed["Ball"] = Version_Table {
		thing   = "Ball",
		rows    = rows,
		next_id = Thing_Id(1),
	}
	return commit_version(prior, changed, allocator)
}

@(test)
test_committed_table_is_id_ascending :: proc(t: ^testing.T) {
	world := make([]Thing_Table, 1, context.temp_allocator)
	world[0] = Thing_Table{thing = "Mote", singleton = false, next_id = Thing_Id(0)}
	prior := initial_version(World{tables = world}, context.temp_allocator)

	state := new_tick_state(prior, context.temp_allocator)
	queue_spawn(&state, "Mote", mote_blackboard(0))
	queue_spawn(&state, "Mote", mote_blackboard(1))
	queue_spawn(&state, "Mote", mote_blackboard(2))
	apply_spawn_batch(&state)

	table := find_tick_table(state.tables, "Mote")
	testing.expect(t, table != nil)
	table.rows[0], table.rows[2] = table.rows[2], table.rows[0]

	next := commit_tick_state(prior, &state, context.temp_allocator)
	committed := view_of_type(&next, "Mote")
	testing.expect_value(t, view_count(committed), 3)

	for i in 0 ..< view_count(committed) {
		row, _ := view_at(committed, i)
		testing.expect_value(t, row.id, Id{raw = Thing_Id(i)})
	}

	for want_id in 0 ..< 3 {
		ref := Ref{thing = "Mote", id = Id{raw = Thing_Id(want_id)}}
		row, some := resolve_ref(&next, ref)
		testing.expect(t, some)
		seq, _ := row_field(row, "seq")
		testing.expect_value(t, seq.(i64), i64(want_id))
	}
}

@(private = "file")
mote_blackboard :: proc(seq: i64, allocator := context.temp_allocator) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, allocator)
	fields["seq"] = seq
	return fields
}

@(test)
test_spawn_batch_at_tick_boundary :: proc(t: ^testing.T) {
	world := make([]Thing_Table, 1, context.temp_allocator)
	world[0] = Thing_Table{thing = "Mote", singleton = false, next_id = Thing_Id(0)}
	prior := initial_version(World{tables = world}, context.temp_allocator)

	state := new_tick_state(prior, context.temp_allocator)
	queue_spawn(&state, "Mote", mote_blackboard(0))
	queue_spawn(&state, "Mote", mote_blackboard(1))

	table := find_tick_table(state.tables, "Mote")
	testing.expect(t, table != nil)
	testing.expect_value(t, len(table.rows), 0)

	apply_spawn_batch(&state)
	tick_a := commit_tick_state(prior, &state, context.temp_allocator)
	testing.expect_value(t, view_count(view_of_type(&tick_a, "Mote")), 2)

	state_b := new_tick_state(tick_a, context.temp_allocator)
	queue_despawn(&state_b, Ref{thing = "Mote", id = Id{raw = Thing_Id(0)}})
	queue_spawn(&state_b, "Mote", mote_blackboard(2))
	apply_spawn_batch(&state_b)
	tick_b := commit_tick_state(tick_a, &state_b, context.temp_allocator)

	motes := view_of_type(&tick_b, "Mote")
	testing.expect_value(t, view_count(motes), 2)
	row0, _ := view_at(motes, 0)
	row1, _ := view_at(motes, 1)
	testing.expect_value(t, row0.id, Id{raw = Thing_Id(1)})
	testing.expect_value(t, row1.id, Id{raw = Thing_Id(2)})
	_, gone := resolve_ref(&tick_b, Ref{thing = "Mote", id = Id{raw = Thing_Id(0)}})
	testing.expect(t, !gone)
}
