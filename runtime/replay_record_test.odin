package funpack_runtime

import "core:testing"

REC_STEER :: ActionId(0)
REC_FIRE :: ActionId(1)
REC_JUMP :: ActionId(2)

@(private = "file")
test_identity :: proc() -> Replay_Identity {
	return Replay_Identity {
		artifact_schema_version = 1,
		project_name = "pong",
		project_version = "0.1.0",
		tick_hz = 60,
		content_hash = 0xdead_beef_0000_0001,
	}
}

@(private = "file")
set_button :: proc(snapshot: ^Input, player: PlayerId, action: ActionId, state: Button_State) {
	snapshot.buttons[Player_Action{player, action}] = state
}

@(private = "file")
set_axis :: proc(snapshot: ^Input, player: PlayerId, action: ActionId, vec: Vec2) {
	snapshot.axes[Player_Action{player, action}] = vec
}

@(private = "file")
record_one :: proc(snapshot: Input, allocator := context.allocator) -> string {
	writer := open_replay_writer(test_identity(), allocator)
	defer delete_replay_writer(&writer)
	record_tick(&writer, snapshot, allocator)
	return finish_replay(&writer, allocator)
}

@(test)
test_recording_is_byte_identical_across_runs :: proc(t: ^testing.T) {
	build_run :: proc(allocator := context.allocator) -> string {
		writer := open_replay_writer(test_identity(), allocator)
		defer delete_replay_writer(&writer)

		t0 := with_pressed(empty(), .P1, REC_FIRE)
		defer delete_input(t0)
		record_tick(&writer, t0, allocator)

		t1 := with_value(empty(), .P1, REC_STEER, fixed_neg(to_fixed(1)))
		defer delete_input(t1)
		record_tick(&writer, t1, allocator)

		t2 := empty()
		defer delete_input(t2)
		set_button(&t2, .P2, REC_JUMP, Button_State{held = true})
		record_tick(&writer, t2, allocator)

		return finish_replay(&writer, allocator)
	}

	first := build_run(context.temp_allocator)
	second := build_run(context.temp_allocator)
	testing.expect_value(t, first, second)
}

@(test)
test_recording_is_insensitive_to_insertion_order :: proc(t: ^testing.T) {
	forward := empty()
	defer delete_input(forward)
	set_button(&forward, .P1, REC_FIRE, Button_State{pressed = true, held = true})
	set_button(&forward, .P1, REC_JUMP, Button_State{held = true})
	set_axis(&forward, .P2, REC_STEER, Vec2{to_fixed(1), Fixed(0)})

	reverse := empty()
	defer delete_input(reverse)
	set_axis(&reverse, .P2, REC_STEER, Vec2{to_fixed(1), Fixed(0)})
	set_button(&reverse, .P1, REC_JUMP, Button_State{held = true})
	set_button(&reverse, .P1, REC_FIRE, Button_State{pressed = true, held = true})

	forward_log := record_one(forward, context.temp_allocator)
	reverse_log := record_one(reverse, context.temp_allocator)
	testing.expect_value(t, forward_log, reverse_log)
}

@(test)
test_snapshot_round_trips_through_query_api :: proc(t: ^testing.T) {
	original := empty()
	defer delete_input(original)
	set_button(&original, .P1, REC_FIRE, Button_State{pressed = true, held = true})
	set_button(&original, .P2, REC_JUMP, Button_State{held = true})
	quarter := fixed_from_decimal(0, "25")
	set_axis(&original, .P3, REC_STEER, Vec2{fixed_neg(quarter), Fixed(0)})

	log_bytes := record_one(original, context.temp_allocator)
	log, ok := read_replay(log_bytes, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	if !testing.expect_value(t, len(log.snapshots), 1) {
		return
	}
	round_tripped := log.snapshots[0]

	testing.expect_value(t, pressed(round_tripped, .P1, REC_FIRE), pressed(original, .P1, REC_FIRE))
	testing.expect_value(t, held(round_tripped, .P1, REC_FIRE), held(original, .P1, REC_FIRE))
	testing.expect_value(t, held(round_tripped, .P2, REC_JUMP), held(original, .P2, REC_JUMP))
	testing.expect_value(t, pressed(round_tripped, .P2, REC_JUMP), pressed(original, .P2, REC_JUMP))
	testing.expect_value(t, value(round_tripped, .P3, REC_STEER), value(original, .P3, REC_STEER))
	testing.expect_value(t, axis(round_tripped, .P3, REC_STEER), axis(original, .P3, REC_STEER))
	testing.expect_value(t, pressed(round_tripped, .P4, REC_FIRE), false)
	testing.expect_value(t, value(round_tripped, .P4, REC_STEER), Fixed(0))
}

@(test)
test_round_trip_preserves_released_edge :: proc(t: ^testing.T) {
	original := empty()
	defer delete_input(original)
	set_button(&original, .P1, REC_FIRE, Button_State{pressed = false, released = true, held = false})

	log_bytes := record_one(original, context.temp_allocator)
	log, ok := read_replay(log_bytes, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	round_tripped := log.snapshots[0]
	testing.expect_value(t, released(round_tripped, .P1, REC_FIRE), true)
	testing.expect_value(t, pressed(round_tripped, .P1, REC_FIRE), false)
	testing.expect_value(t, held(round_tripped, .P1, REC_FIRE), false)
}

@(test)
test_header_pins_artifact_identity :: proc(t: ^testing.T) {
	program, prog_ok := load_golden(t)
	if !prog_ok {
		return
	}
	identity := identity_from_program(program, GOLDEN_ARTIFACT)

	writer := open_replay_writer(identity, context.temp_allocator)
	defer delete_replay_writer(&writer)
	snap := with_pressed(empty(), .P1, REC_FIRE)
	defer delete_input(snap)
	record_tick(&writer, snap, context.temp_allocator)
	log_bytes := finish_replay(&writer, context.temp_allocator)

	log, ok := read_replay(log_bytes, context.temp_allocator)
	if !testing.expect(t, ok) {
		return
	}
	testing.expect_value(t, log.identity.artifact_schema_version, program.schema_version)
	testing.expect_value(t, log.identity.project_name, program.meta.name)
	testing.expect_value(t, log.identity.project_version, program.meta.version)
	testing.expect_value(t, log.identity.tick_hz, program.entrypoint.tick_hz)
	testing.expect_value(t, log.identity.content_hash, identity.content_hash)
}

@(test)
test_content_hash_distinguishes_builds :: proc(t: ^testing.T) {
	a := identity_from_program(Program{}, "funpack-artifact 1\n[meta 0]\n")
	b := identity_from_program(Program{}, "funpack-artifact 1\n[meta 1]\n")
	testing.expect(t, a.content_hash != b.content_hash)
}

@(test)
test_read_replay_refuses_wrong_magic :: proc(t: ^testing.T) {
	_, bad_magic_ok := read_replay("notreplay 2\n[ticks 0]\n", context.temp_allocator)
	testing.expect(t, !bad_magic_ok)

	_, bad_version_ok := read_replay("funpack-replay 1\n[ticks 0]\n", context.temp_allocator)
	testing.expect(t, !bad_version_ok)
}
