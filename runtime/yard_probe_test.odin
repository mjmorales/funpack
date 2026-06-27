package funpack_runtime

import "core:testing"

@(private = "file")
YARD_DELIVERY_TICK :: 726

@(private = "file")
yard_scoreboard_delivered :: proc(version: ^World_Version) -> i64 {
	table := version_find_table(version, "Scoreboard")
	if table == nil || len(table.rows) == 0 {
		return -1
	}
	d, ok := table.rows[0].fields["delivered"].(i64)
	if !ok {
		return -1
	}
	return d
}

@(private = "file")
yard_crate_count :: proc(version: ^World_Version) -> int {
	table := version_find_table(version, "Crate")
	if table == nil {
		return -1
	}
	return len(table.rows)
}

@(private = "file")
yard_camera_shake :: proc(version: ^World_Version) -> Vec2 {
	table := version_find_table(version, "Camera")
	if table == nil || len(table.rows) == 0 {
		return VEC2_ZERO
	}
	s, ok := table.rows[0].fields["shake"].(Vec2)
	if !ok {
		return VEC2_ZERO
	}
	return s
}

@(test)
test_yard_pad_body_decodes_the_sensor_flag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program, ok := load_yard(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	version := run_startup(&program, initial_version(world, context.temp_allocator))

	pad := version_find_table(&version, "Pad")
	if !testing.expect(t, pad != nil && len(pad.rows) == 1) {
		return
	}
	body, is_record := pad.rows[0].fields["body"].(Record_Value)
	if !testing.expect(t, is_record) {
		return
	}
	testing.expect_value(t, body_record_bool(body, "sensor"), true)
}

@(test)
test_yard_scripted_session_delivers_at_exact_tick :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program, ok := load_yard(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	version := run_startup(&program, initial_version(world, context.temp_allocator))
	time := yard_time(program.entrypoint.tick_hz)
	inputs := yard_session_inputs()

	testing.expect_value(t, yard_crate_count(&version), 3)
	testing.expect_value(t, yard_scoreboard_delivered(&version), 0)

	delivered := make([]i64, len(inputs), context.temp_allocator)
	crate_count := make([]int, len(inputs), context.temp_allocator)
	shake := make([]Vec2, len(inputs), context.temp_allocator)
	for input, i in inputs {
		version = step_tick(&program, version, input, time)
		delivered[i] = yard_scoreboard_delivered(&version)
		crate_count[i] = yard_crate_count(&version)
		shake[i] = yard_camera_shake(&version)
	}

	testing.expect_value(t, delivered[YARD_DELIVERY_TICK - 1], 0)
	testing.expect_value(t, crate_count[YARD_DELIVERY_TICK - 1], 3)
	testing.expect_value(t, shake[YARD_DELIVERY_TICK - 1], VEC2_ZERO)

	testing.expect_value(t, delivered[YARD_DELIVERY_TICK], 1)
	testing.expect_value(t, crate_count[YARD_DELIVERY_TICK], 2)
	testing.expect_value(t, shake[YARD_DELIVERY_TICK], Vec2{yard_shake_kick(), Fixed(0)})

	testing.expect_value(t, shake[YARD_DELIVERY_TICK + 1], Vec2{yard_shake_decay_1(), Fixed(0)})
	testing.expect_value(t, delivered[len(delivered) - 1], 1)
	testing.expect_value(t, crate_count[len(crate_count) - 1], 2)
}
