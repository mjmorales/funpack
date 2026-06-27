package funpack_runtime

import "core:testing"

@(private = "file")
PONG_FIRST_BOUNCE_TICK :: 58

@(private = "file")
PONG_BALL_VX0 :: Fixed(300647710720)

@(private = "file")
pong_ball_vel_x :: proc(version: ^World_Version) -> Fixed {
	table := version_find_table(version, "Ball")
	if table == nil || len(table.rows) == 0 {
		return FIXED_MIN
	}
	vel, ok := table.rows[0].fields["vel"].(Vec2)
	if !ok {
		return FIXED_MIN
	}
	return vel.x
}

@(test)
test_pong_scripted_session_bounces_off_paddle_at_exact_tick :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	program, ok := load_golden(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	version := run_startup(&program, initial_version(world, context.temp_allocator))
	time := time_resource(program.entrypoint.tick_hz, context.temp_allocator)
	inputs := golden_session_inputs()

	vel_x := make([]Fixed, len(inputs), context.temp_allocator)
	bounce_ticks := make([dynamic]int, context.temp_allocator)
	prev := pong_ball_vel_x(&version)
	for input, i in inputs {
		version = step_tick(&program, version, input, time)
		vel_x[i] = pong_ball_vel_x(&version)
		if (prev > 0) != (vel_x[i] > 0) {
			append(&bounce_ticks, i)
		}
		prev = vel_x[i]
	}

	testing.expect_value(t, vel_x[PONG_FIRST_BOUNCE_TICK - 1], PONG_BALL_VX0)

	testing.expect_value(t, vel_x[PONG_FIRST_BOUNCE_TICK], fixed_neg(PONG_BALL_VX0))

	if !testing.expect(t, len(bounce_ticks) >= 1) {
		return
	}
	testing.expect_value(t, bounce_ticks[0], PONG_FIRST_BOUNCE_TICK)
}
