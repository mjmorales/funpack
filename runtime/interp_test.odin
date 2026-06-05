// Interpreter proof over the §2.7 node forest: the evaluator computes the
// canonical semantics of pong's function and behavior bodies straight from the
// golden artifact (spec §09 §1 — the interpreter IS the semantics, no source on
// its path). These tests pin the worked examples the loader tests reference
// (advance, overlaps, goal_side, serve_velocity, add_goal) to their bit-exact
// kernel results, so a body's MEANING is asserted, not just its shape.
package funpack_runtime

import "core:testing"

// make_interp builds a read-only interpreter over the golden program with an
// empty input snapshot and the fixed 60hz dt — the context a helper-body
// evaluation reads against. The version is the empty initial one; tests that
// need rows commit their own.
@(private = "file")
make_interp :: proc(program: ^Program, version: ^World_Version) -> Interp {
	dt_fields := make(map[string]Value, context.temp_allocator)
	dt_fields["dt"] = dt_60hz()
	return Interp {
		program = program,
		version = version,
		input = empty(),
		time = Record_Value{type_name = "Time", fields = dt_fields},
		allocator = context.temp_allocator,
	}
}

// dt_60hz is the fixed 60hz step the Time resource carries: 1/60 in Q32.32,
// derived through the kernel so no float reaches the value.
@(private = "file")
dt_60hz :: proc() -> Fixed {
	return fixed_div(to_fixed(1), to_fixed(60))
}

// BOARD reads as the interpreted Board const: a body that reads BOARD.w/h
// resolves against this evaluated record with no source needed (§9 const path).
@(test)
test_eval_const_board :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	board, board_ok := eval_const(&interp, "BOARD")
	testing.expect(t, board_ok)
	record, is_record := board.(Record_Value)
	testing.expect(t, is_record)
	w, w_present := record.fields["w"]
	h, h_present := record.fields["h"]
	testing.expect(t, w_present && h_present)
	testing.expect_value(t, w.(Fixed), to_fixed(160))
	testing.expect_value(t, h.(Fixed), to_fixed(120))
}

// advance(at, vel, dt) returns at + vel*dt — the §2.7 worked example. With
// at=(80,60), vel=(70,40), dt=1/60, the result is the bit-exact kernel value, so
// a body's arithmetic is the determinism path, not a float.
@(test)
test_eval_user_call_advance :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	at := Vec2{to_fixed(80), to_fixed(60)}
	vel := Vec2{to_fixed(70), to_fixed(40)}
	dt := dt_60hz()
	result, result_ok := call_three(&interp, "advance", at, vel, dt)
	testing.expect(t, result_ok)

	got := result.(Vec2)
	want := Vec2{fixed_add(at.x, fixed_mul(vel.x, dt)), fixed_add(at.y, fixed_mul(vel.y, dt))}
	testing.expect_value(t, got.x, want.x)
	testing.expect_value(t, got.y, want.y)
}

// goal_side(at) returns Some(Right) for x<0, Some(Left) for x>BOARD.w, None
// otherwise — the §2.7 three-statement if_return/return example. Both edges and
// the in-bounds case are forced, so the match a behavior runs over it is exact.
@(test)
test_eval_goal_side_all_arms :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	// x < 0 → Some(Right).
	left_edge := goal_side_case(&interp, Vec2{fixed_neg(to_fixed(5)), to_fixed(60)})
	testing.expect_value(t, left_edge.case_name, "Some")
	testing.expect_value(t, left_edge.payload.(Variant_Value).case_name, "Right")

	// x > BOARD.w (160) → Some(Left).
	right_edge := goal_side_case(&interp, Vec2{to_fixed(200), to_fixed(60)})
	testing.expect_value(t, right_edge.case_name, "Some")
	testing.expect_value(t, right_edge.payload.(Variant_Value).case_name, "Left")

	// 0 ≤ x ≤ 160 → None.
	in_bounds := goal_side_case(&interp, Vec2{to_fixed(80), to_fixed(60)})
	testing.expect_value(t, in_bounds.case_name, "None")
}

// add_goal(score, goal) increments the side the goal scored — the §2.7 match-over-
// a-field-scrutinee example. A Left goal bumps left, a Right goal bumps right;
// the OTHER column is left untouched, proving the `with` is a functional update.
@(test)
test_eval_add_goal_increments_side :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	score := record_value(&interp, "Scoreboard", {"left", i64(2)}, {"right", i64(5)})
	left_goal := goal_value(&interp, "Left")
	updated, updated_ok := call_two(&interp, "add_goal", score, left_goal)
	testing.expect(t, updated_ok)

	out := updated.(Record_Value)
	testing.expect_value(t, out.fields["left"].(i64), i64(3))
	testing.expect_value(t, out.fields["right"].(i64), i64(5)) // untouched
}

// serve_velocity(side) returns the §2.7 match-over-an-enum example: Left serves
// (+70, +40), Right serves (−70, +40). The kernel-negated x proves the unary neg
// arm folds bit-exact.
@(test)
test_eval_serve_velocity :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_interp(&program, &version)

	left_vel := serve_velocity_for(&interp, "Left")
	testing.expect_value(t, left_vel.x, to_fixed(70))
	testing.expect_value(t, left_vel.y, to_fixed(40))

	right_vel := serve_velocity_for(&interp, "Right")
	testing.expect_value(t, right_vel.x, fixed_neg(to_fixed(70)))
	testing.expect_value(t, right_vel.y, to_fixed(40))
}

// --- test call helpers ----------------------------------------------------

// call_three applies a three-arg §9 helper directly by building a call over name
// nodes that resolve from a seeded scope — the test driver for a body whose args
// are runtime values rather than literals.
@(private = "file")
call_three :: proc(
	interp: ^Interp,
	name: string,
	a, b, c: Value,
) -> (
	result: Value,
	ok: bool,
) {
	fn := program_function(interp.program, name)
	if fn == nil || len(fn.params) != 3 {
		return nil, false
	}
	scope := Env{names = make(map[string]Value, interp.allocator)}
	scope.names[fn.params[0].name] = a
	scope.names[fn.params[1].name] = b
	scope.names[fn.params[2].name] = c
	return eval_body(interp, fn.body, &scope)
}

// call_two applies a two-arg §9 helper directly against seeded params.
@(private = "file")
call_two :: proc(interp: ^Interp, name: string, a, b: Value) -> (result: Value, ok: bool) {
	fn := program_function(interp.program, name)
	if fn == nil || len(fn.params) != 2 {
		return nil, false
	}
	return apply_two_arg(interp, fn, a, b)
}

// call_one applies a one-arg §9 helper directly against its seeded param.
@(private = "file")
call_one :: proc(interp: ^Interp, name: string, a: Value) -> (result: Value, ok: bool) {
	fn := program_function(interp.program, name)
	if fn == nil || len(fn.params) != 1 {
		return nil, false
	}
	scope := Env{names = make(map[string]Value, interp.allocator)}
	scope.names[fn.params[0].name] = a
	return eval_body(interp, fn.body, &scope)
}

// goal_side_case runs goal_side over a position and returns the resulting Option
// variant for arm inspection.
@(private = "file")
goal_side_case :: proc(interp: ^Interp, at: Vec2) -> Variant_Value {
	result, ok := call_one(interp, "goal_side", at)
	if !ok {
		return Variant_Value{}
	}
	return result.(Variant_Value)
}

// serve_velocity_for runs serve_velocity over a side variant and returns the Vec2.
@(private = "file")
serve_velocity_for :: proc(interp: ^Interp, side: string) -> Vec2 {
	result, ok := call_one(interp, "serve_velocity", side_value(interp, side))
	if !ok {
		return VEC2_ZERO
	}
	return result.(Vec2)
}

// record_value builds a Record_Value fixture from name/value pairs — the
// descriptor-driven stand-in for a typed record literal in a test.
@(private = "file")
record_value :: proc(
	interp: ^Interp,
	type_name: string,
	pairs: ..struct {
		name:  string,
		value: Value,
	},
) -> Value {
	fields := make(map[string]Value, interp.allocator)
	for pair in pairs {
		fields[pair.name] = pair.value
	}
	return Record_Value{type_name = type_name, fields = fields}
}

// side_value builds a Side enum variant value for a serve/score fixture.
@(private = "file")
side_value :: proc(interp: ^Interp, case_name: string) -> Value {
	return Variant_Value{enum_type = "Side", case_name = case_name}
}

// goal_value builds a Goal signal record carrying a side — the element add_goal
// folds and serve reads.
@(private = "file")
goal_value :: proc(interp: ^Interp, side: string) -> Value {
	fields := make(map[string]Value, interp.allocator)
	fields["side"] = side_value(interp, side)
	return Record_Value{type_name = "Goal", fields = fields}
}
