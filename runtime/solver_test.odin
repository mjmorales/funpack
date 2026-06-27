package funpack_runtime

import "core:mem"
import "core:testing"

@(test)
test_solver_double_fold_is_byte_identical :: proc(t: ^testing.T) {
	a := context.temp_allocator
	program := solve_program(a)
	base := two_body_world(
		a,
		moving_crate(Vec2{to_fixed(50), to_fixed(40)}, Vec2{to_fixed(8), to_fixed(0)}),
		static_wall(Vec2{to_fixed(60), to_fixed(40)}, Vec2{to_fixed(8), to_fixed(40)}),
	)

	first := step_tick(&program, base, empty(), solver_time(a), a)
	second := step_tick(&program, base, empty(), solver_time(a), a)

	if !testing.expect(t, world_versions_equal(first, second)) {
		return
	}

	crate_a, _ := view_at(view_of_type(&first, "Crate"), 0)
	crate_b, _ := view_at(view_of_type(&second, "Crate"), 0)
	pos_a, _ := row_field(crate_a, "pos")
	pos_b, _ := row_field(crate_b, "pos")
	vel_a, _ := row_field(crate_a, "vel")
	vel_b, _ := row_field(crate_b, "vel")
	testing.expect_value(t, pos_a.(Vec2), pos_b.(Vec2))
	testing.expect_value(t, vel_a.(Vec2), vel_b.(Vec2))
}

@(test)
test_solver_zeroes_impulse_after_step :: proc(t: ^testing.T) {
	a := context.temp_allocator
	program := solve_program(a)
	pushed := pushed_crate(Vec2{to_fixed(50), to_fixed(40)}, Vec2{to_fixed(5), to_fixed(3)})
	base := one_body_world(a, pushed)

	next := step_tick(&program, base, empty(), solver_time(a), a)

	crate, _ := view_at(view_of_type(&next, "Crate"), 0)
	body := body_column(crate)
	impulse := body.fields["impulse"].(Vec2)
	testing.expect_value(t, impulse, VEC2_ZERO)

	vel, _ := row_field(crate, "vel")
	testing.expect(t, vel.(Vec2) != VEC2_ZERO)
}

@(test)
test_solver_sensor_overlap_routes_trigger_unresolved :: proc(t: ^testing.T) {
	a := context.temp_allocator
	crate := resting_crate(Vec2{to_fixed(80), to_fixed(100)})
	pad := pad_sensor(Vec2{to_fixed(80), to_fixed(100)}, Vec2{to_fixed(24), to_fixed(24)})

	state := solve_one_step_state(a, crate, pad)

	testing.expect_value(t, total_routed_triggers(state), 1)

	pad_table := find_tick_table(state.tables, "Pad")
	if !testing.expect(t, pad_table != nil) {
		return
	}
	pad_pos := pad_table.rows[0].fields["pos"].(Vec2)
	testing.expect_value(t, pad_pos, Vec2{to_fixed(80), to_fixed(100)})
}

@(test)
test_solver_sensor_routes_one_trigger_per_overlapping_body :: proc(t: ^testing.T) {
	a := context.temp_allocator
	program := solve_program(a)
	base := three_body_world(
		a,
		"Crate",
		resting_crate(Vec2{to_fixed(74), to_fixed(100)}),
		resting_crate(Vec2{to_fixed(86), to_fixed(100)}),
		"Pad",
		pad_sensor(Vec2{to_fixed(80), to_fixed(100)}, Vec2{to_fixed(40), to_fixed(40)}),
	)

	state := new_tick_state(base, a)
	prior := base
	interp := new_interp(&program, &prior, &state, empty(), solver_time(a), a)
	run_solve(&interp, &state)

	testing.expect_value(t, total_routed_triggers(state), 2)
	crate_table := find_tick_table(state.tables, "Crate")
	if !testing.expect(t, crate_table != nil && len(crate_table.rows) == 2) {
		return
	}
	testing.expect_value(t, triggers_for(state, crate_table.rows[0].id), 1)
	testing.expect_value(t, triggers_for(state, crate_table.rows[1].id), 1)
}

@(test)
test_solver_mask_mismatch_yields_no_contact :: proc(t: ^testing.T) {
	a := context.temp_allocator
	player := player_over_pad(Vec2{to_fixed(80), to_fixed(100)})
	pad := pad_sensor_masking(Vec2{to_fixed(80), to_fixed(100)}, Vec2{to_fixed(24), to_fixed(24)}, "Player")

	state := solve_one_step_state_named(a, "Player", player, "Pad", pad)

	testing.expect_value(t, total_routed_triggers(state), 0)

	player_table := find_tick_table(state.tables, "Player")
	if !testing.expect(t, player_table != nil) {
		return
	}
	player_pos := player_table.rows[0].fields["pos"].(Vec2)
	testing.expect_value(t, player_pos, Vec2{to_fixed(80), to_fixed(100)})
}

@(test)
test_solver_non_overlapping_matched_pair_no_trigger :: proc(t: ^testing.T) {
	a := context.temp_allocator
	crate := resting_crate(Vec2{to_fixed(10), to_fixed(10)})
	pad := pad_sensor(Vec2{to_fixed(200), to_fixed(200)}, Vec2{to_fixed(24), to_fixed(24)})

	state := solve_one_step_state(a, crate, pad)

	testing.expect_value(t, total_routed_triggers(state), 0)
}

@(private = "file")
total_routed_triggers :: proc(state: Tick_State) -> int {
	per_type, has := state.mailbox.by_instance[SOLVER_TRIGGER_SIGNAL]
	if !has {
		return 0
	}
	total := 0
	for _, list in per_type {
		total += len(list)
	}
	return total
}

@(private = "file")
triggers_for :: proc(state: Tick_State, target: Id) -> int {
	per_type, has := state.mailbox.by_instance[SOLVER_TRIGGER_SIGNAL]
	if !has {
		return 0
	}
	return len(per_type[target])
}

@(private = "file")
solver_time :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

@(private = "file")
solve_program :: proc(allocator := context.allocator) -> Program {
	pipeline := make([]Pipeline_Step, 1, allocator)
	pipeline[0] = Pipeline_Step{ordinal = 0, stage = "physics", behavior = "solve"}
	return Program{pipeline = pipeline}
}

@(private = "file")
solve_one_step_state :: proc(
	allocator: mem.Allocator,
	crate, pad: map[string]Field_Value,
) -> Tick_State {
	return solve_one_step_state_named(allocator, "Crate", crate, "Pad", pad)
}

@(private = "file")
solve_one_step_state_named :: proc(
	allocator: mem.Allocator,
	thing_a: string,
	body_a: map[string]Field_Value,
	thing_b: string,
	body_b: map[string]Field_Value,
) -> Tick_State {
	program := solve_program(allocator)
	base := two_body_world_named(allocator, thing_a, body_a, thing_b, body_b)
	state := new_tick_state(base, allocator)
	prior := base
	interp := new_interp(&program, &prior, &state, empty(), solver_time(allocator), allocator)
	run_solve(&interp, &state)
	return state
}

@(private = "file")
one_body_world :: proc(allocator: mem.Allocator, crate: map[string]Field_Value) -> World_Version {
	tables := make([]Version_Table, 1, allocator)
	tables[0] = single_row_table("Crate", crate, allocator)
	return World_Version{tick = 0, tables = tables}
}

@(private = "file")
two_body_world :: proc(allocator: mem.Allocator, crate, wall: map[string]Field_Value) -> World_Version {
	return two_body_world_named(allocator, "Crate", crate, "Wall", wall)
}

@(private = "file")
two_body_world_named :: proc(
	allocator: mem.Allocator,
	thing_a: string,
	body_a: map[string]Field_Value,
	thing_b: string,
	body_b: map[string]Field_Value,
) -> World_Version {
	tables := make([]Version_Table, 2, allocator)
	tables[0] = single_row_table(thing_a, body_a, allocator)
	tables[1] = single_row_table(thing_b, body_b, allocator)
	return World_Version{tick = 0, tables = tables}
}

@(private = "file")
three_body_world :: proc(
	allocator: mem.Allocator,
	thing_a: string,
	body_a0, body_a1: map[string]Field_Value,
	thing_b: string,
	body_b: map[string]Field_Value,
) -> World_Version {
	tables := make([]Version_Table, 2, allocator)
	rows_a := make([]Row, 2, allocator)
	rows_a[0] = Row{id = Id{raw = 0}, fields = body_a0}
	rows_a[1] = Row{id = Id{raw = 1}, fields = body_a1}
	tables[0] = Version_Table{thing = thing_a, rows = rows_a, next_id = Thing_Id(2)}
	tables[1] = single_row_table(thing_b, body_b, allocator)
	return World_Version{tick = 0, tables = tables}
}

@(private = "file")
single_row_table :: proc(thing: string, fields: map[string]Field_Value, allocator := context.allocator) -> Version_Table {
	rows := make([]Row, 1, allocator)
	rows[0] = Row{id = Id{raw = 0}, fields = fields}
	return Version_Table{thing = thing, rows = rows, next_id = Thing_Id(1)}
}

@(private = "file")
moving_crate :: proc(pos, vel: Vec2) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, context.temp_allocator)
	fields["pos"] = pos
	fields["vel"] = vel
	fields["body"] = crate_body_col(VEC2_ZERO)
	return fields
}

@(private = "file")
pushed_crate :: proc(pos, impulse: Vec2) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, context.temp_allocator)
	fields["pos"] = pos
	fields["vel"] = VEC2_ZERO
	fields["body"] = crate_body_col(impulse)
	return fields
}

@(private = "file")
resting_crate :: proc(pos: Vec2) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, context.temp_allocator)
	fields["pos"] = pos
	fields["vel"] = VEC2_ZERO
	fields["body"] = crate_body_col(VEC2_ZERO)
	return fields
}

@(private = "file")
static_wall :: proc(pos, size: Vec2) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, context.temp_allocator)
	fields["pos"] = pos
	fields["body"] = wall_body_col(size)
	return fields
}

@(private = "file")
pad_sensor :: proc(pos, size: Vec2) -> map[string]Field_Value {
	return pad_sensor_masking(pos, size, "Crate")
}

@(private = "file")
pad_sensor_masking :: proc(pos, size: Vec2, mask_layer: string) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, context.temp_allocator)
	fields["pos"] = pos
	fields["body"] = sensor_body_col(size, mask_layer)
	return fields
}

@(private = "file")
player_over_pad :: proc(pos: Vec2) -> map[string]Field_Value {
	fields := make(map[string]Field_Value, context.temp_allocator)
	fields["pos"] = pos
	fields["vel"] = VEC2_ZERO
	fields["body"] = player_body_col()
	return fields
}

@(private = "file")
crate_body_col :: proc(impulse: Vec2) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["kind"] = enum_token("BodyKind", "Dynamic")
	fields["shape"] = box_shape(Vec2{to_fixed(12), to_fixed(12)})
	fields["mass"] = to_fixed(2)
	fields["friction"] = fixed_from_decimal(0, "9")
	fields["sensor"] = false
	fields["layer"] = enum_token("Layer", "Crate")
	fields["mask"] = layer_mask("Wall", "Player", "Crate", "Pad")
	fields["impulse"] = impulse
	return Record_Value{type_name = "Body", fields = fields}
}

@(private = "file")
wall_body_col :: proc(size: Vec2) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["kind"] = enum_token("BodyKind", "Static")
	fields["shape"] = box_shape(size)
	fields["sensor"] = false
	fields["layer"] = enum_token("Layer", "Wall")
	fields["mask"] = layer_mask("Player", "Crate")
	return Record_Value{type_name = "Body", fields = fields}
}

@(private = "file")
sensor_body_col :: proc(size: Vec2, mask_layer: string) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["kind"] = enum_token("BodyKind", "Static")
	fields["shape"] = box_shape(size)
	fields["sensor"] = true
	fields["layer"] = enum_token("Layer", "Pad")
	fields["mask"] = layer_mask(mask_layer)
	return Record_Value{type_name = "Body", fields = fields}
}

@(private = "file")
player_body_col :: proc() -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["kind"] = enum_token("BodyKind", "Dynamic")
	fields["shape"] = circle_shape(to_fixed(5))
	fields["friction"] = fixed_from_decimal(0, "9")
	fields["sensor"] = false
	fields["layer"] = enum_token("Layer", "Player")
	fields["mask"] = layer_mask("Wall", "Crate")
	fields["impulse"] = VEC2_ZERO
	return Record_Value{type_name = "Body", fields = fields}
}

@(private = "file")
box_shape :: proc(size: Vec2) -> Variant_Value {
	payload_fields := make(map[string]Value, context.temp_allocator)
	payload_fields["size"] = size
	payload := new(Value, context.temp_allocator)
	payload^ = Record_Value{type_name = "", fields = payload_fields}
	return Variant_Value{enum_type = "Shape2", case_name = "Box", payload = payload}
}

@(private = "file")
circle_shape :: proc(radius: Fixed) -> Variant_Value {
	payload_fields := make(map[string]Value, context.temp_allocator)
	payload_fields["radius"] = radius
	payload := new(Value, context.temp_allocator)
	payload^ = Record_Value{type_name = "", fields = payload_fields}
	return Variant_Value{enum_type = "Shape2", case_name = "Circle", payload = payload}
}

@(private = "file")
enum_token :: proc(enum_type, case_name: string) -> Variant_Value {
	return Variant_Value{enum_type = enum_type, case_name = case_name}
}

@(private = "file")
layer_mask :: proc(layers: ..string) -> List_Value {
	elements := make([]Value, len(layers), context.temp_allocator)
	for layer, i in layers {
		elements[i] = enum_token("Layer", layer)
	}
	return List_Value{elements = elements}
}

@(private = "file")
body_column :: proc(row: Row) -> Record_Value {
	return row.fields["body"].(Record_Value)
}
