// Yard physics-delivery probe (the yard counterpart of hunt's
// test_scripted_session_cycles_hunter_ai): it pins the EXACT tick the scripted
// session's delivery fires and the committed state it produces, so the golden
// digest provably folds a real delivery event rather than a static world.
//
// THE DELIVERY EVENT THE DIGEST FOLDS (the non-trivial evolving shape that makes
// the per-tick digests distinct): yard_session_inputs drives P1's Drive::Move 2D
// axis to maneuver the Player above the center crate (spawn (80,40)) and push it
// down onto the Pad sensor (spawn (80,100), 24x24). At YARD_DELIVERY_TICK the
// engine routes a per-instance Trigger to the overlapping crate, deliver
// self-despawns it and emits Delivered, tally increments Scoreboard.delivered
// 0->1, and shake kicks Camera.shake to (SHAKE_KICK=4, 0) then flip-halves each
// tick after (the * SHAKE_DAMP=-0.5 decay). Every value here is stable Q32.32
// arithmetic — no RNG, no seed (yard is SEEDLESS, Lore #7/#9) — so a shifted
// delivery tick or a changed shake value is a DETERMINISM regression, not flaky
// timing. The shared session definition (yard_session_inputs) lives in
// yard_acceptance_test.odin so the probe and the golden harness drive the exact
// same run.
package funpack_runtime

import "core:testing"

// YARD_DELIVERY_TICK is the exact tick the center crate lands on the Pad under
// yard_session_inputs: the Trigger routes, deliver despawns the crate + emits
// Delivered, tally takes Scoreboard.delivered 0->1, and shake kicks. It is stable
// arithmetic over the Q32.32 kernel; a change is a determinism regression unless a
// deliberate artifact/solver/encoding change moved it.
@(private = "file")
YARD_DELIVERY_TICK :: 726

// yard_scoreboard_delivered reads the Scoreboard singleton's `delivered` Int at a
// committed version — the tally the delivery increments. An absent table/row or a
// non-Int column yields -1 so the assertion fails closed.
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

// yard_crate_count reports the live Crate row count at a committed version — 3
// before any delivery, 2 after the center crate self-despawns. An absent table
// yields -1 so a missing population fails closed.
@(private = "file")
yard_crate_count :: proc(version: ^World_Version) -> int {
	table := version_find_table(version, "Crate")
	if table == nil {
		return -1
	}
	return len(table.rows)
}

// yard_camera_shake reads the Camera singleton's `shake` Vec2 at a committed
// version — (0,0) at rest, (SHAKE_KICK,0) the delivery tick, then flip-decaying.
// An absent table/row or non-Vec2 column yields the zero vector.
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
	// The Pad's `body: Body` composite setup field decodes its `sensor: true` Bool
	// (the §13 composite spawn-field decode the deliver path gates on): an
	// undecoded/mis-decoded sensor would leave the Pad inert, no Trigger would
	// route, and no crate could ever deliver. This pins the decode at the column
	// level, ahead of the whole scripted run.
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
	// The scripted session lands the center crate on the Pad at exactly
	// YARD_DELIVERY_TICK: Scoreboard.delivered goes 0->1, the Crate table drops a
	// row (3->2 self-despawn), and Camera.shake kicks to (SHAKE_KICK,0) then
	// flip-halves the following ticks. All stable Q32.32 arithmetic (no RNG/seed,
	// Lore #7/#9) — a shifted index or a changed shake value is a determinism
	// regression. This is the proof the golden digest folds a real per-instance
	// delivery (and the per-tick decay tail gives the distinct evolving frames the
	// digest acceptance rests on, not a static world).
	context.allocator = context.temp_allocator

	program, ok := load_yard(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	version := run_startup(&program, initial_version(world, context.temp_allocator))
	time := yard_time(program.entrypoint.tick_hz)
	inputs := yard_session_inputs()

	// Pre-delivery: three crates, nothing delivered, the camera at rest.
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

	// The tick BEFORE delivery: still three crates, nothing tallied, camera at rest.
	testing.expect_value(t, delivered[YARD_DELIVERY_TICK - 1], 0)
	testing.expect_value(t, crate_count[YARD_DELIVERY_TICK - 1], 3)
	testing.expect_value(t, shake[YARD_DELIVERY_TICK - 1], VEC2_ZERO)

	// The delivery tick: tally 0->1, one crate despawned (3->2), shake kicked.
	testing.expect_value(t, delivered[YARD_DELIVERY_TICK], 1)
	testing.expect_value(t, crate_count[YARD_DELIVERY_TICK], 2)
	testing.expect_value(t, shake[YARD_DELIVERY_TICK], Vec2{yard_shake_kick(), Fixed(0)})

	// The tick AFTER: the shake flips sign and halves (* SHAKE_DAMP = -0.5), the
	// deterministic decay — distinct from the kick, so the digest folds an evolving
	// tail. Only the center crate ever delivers, so the tally holds at 1 and two
	// crates remain through the session end.
	testing.expect_value(t, shake[YARD_DELIVERY_TICK + 1], Vec2{yard_shake_decay_1(), Fixed(0)})
	testing.expect_value(t, delivered[len(delivered) - 1], 1)
	testing.expect_value(t, crate_count[len(crate_count) - 1], 2)
}
