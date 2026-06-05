// Recording-side proof for §23 §4: the per-tick resolved-snapshot replay log
// records deterministically. The tests prove the three load-bearing properties —
// (1) recording a FIXED snapshot sequence twice yields BYTE-IDENTICAL logs, and a
// snapshot built in a different insertion order still records identically (the
// sorted-key enumeration defeats Odin's unspecified map order); (2) a recorded
// snapshot ROUND-TRIPS to an Input the query API reads identically to the original,
// including a `released` edge and a `held`-without-`pressed` level no producer sets;
// and (3) the header PINS the artifact identity derived from the real golden pong
// artifact, so a replay can refuse a mismatched build. RAW device state never
// appears — every snapshot is built in the device-free producer/table vocabulary.
package funpack_runtime

import "core:testing"

// REC_STEER / REC_FIRE / REC_JUMP are stable action-id stand-ins for the recording
// tests — the recorder keys generically by ActionId, so it never depends on pong's
// enums (matching the snapshot-core test convention).
REC_STEER :: ActionId(0) // an Axis-kinded action stand-in
REC_FIRE :: ActionId(1) // a Button-kinded action stand-in
REC_JUMP :: ActionId(2)

// test_identity is a fixed artifact identity the recording tests pin without
// touching the artifact loader — distinct fields so a mis-ordered header field
// would change the bytes observably.
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

// set_button writes a resolved button state straight into a snapshot's table — the
// way bindings resolution builds a resolved snapshot (it can carry a `released`
// edge or a `held`-without-`pressed` level no producer expresses). Building tables
// directly also avoids the producer chain's intermediate-clone leak, so a test
// assembles a multi-action snapshot without leaking. The snapshot is taken by
// pointer because a map mutated through a parameter must pass as ^map — a by-value
// Input copies the map header and the insert would not reach the caller's table.
@(private = "file")
set_button :: proc(snapshot: ^Input, player: PlayerId, action: ActionId, state: Button_State) {
	snapshot.buttons[Player_Action{player, action}] = state
}

// set_axis writes a resolved axis reading straight into a snapshot's table. Taken
// by pointer for the same reason as set_button.
@(private = "file")
set_axis :: proc(snapshot: ^Input, player: PlayerId, action: ActionId, vec: Vec2) {
	snapshot.axes[Player_Action{player, action}] = vec
}

// record_one logs a single snapshot against test_identity and returns the finished
// log bytes — the common shape the byte-stability and round-trip tests build on.
@(private = "file")
record_one :: proc(snapshot: Input, allocator := context.allocator) -> string {
	writer := open_replay_writer(test_identity(), allocator)
	defer delete_replay_writer(&writer)
	record_tick(&writer, snapshot, allocator)
	return finish_replay(&writer, allocator)
}

@(test)
test_recording_is_byte_identical_across_runs :: proc(t: ^testing.T) {
	// The same snapshot sequence recorded twice must produce byte-identical logs
	// — the determinism invariant (§23 §4). A three-tick run mixing button edges
	// and axis readings exercises both record kinds.
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
	// Two snapshots that are EQUAL but were built by inserting their keys in
	// opposite orders must record byte-identically: the sorted-key enumeration is
	// what defeats Odin's unspecified map iteration order, so the recorded bytes
	// depend on the snapshot's CONTENT, not how it was assembled (§23 §4).
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
	// A recorded snapshot must round-trip to an Input the query API reads
	// identically — the property a replay re-fold depends on (§23 §4). The
	// snapshot carries a button with a HELD-without-PRESSED level, an axis reading,
	// and an untouched action that must read its zero default after the round-trip.
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

	// The button edges/levels read back identically...
	testing.expect_value(t, pressed(round_tripped, .P1, REC_FIRE), pressed(original, .P1, REC_FIRE))
	testing.expect_value(t, held(round_tripped, .P1, REC_FIRE), held(original, .P1, REC_FIRE))
	testing.expect_value(t, held(round_tripped, .P2, REC_JUMP), held(original, .P2, REC_JUMP))
	testing.expect_value(t, pressed(round_tripped, .P2, REC_JUMP), pressed(original, .P2, REC_JUMP))
	// ...the axis reads back bit-exact...
	testing.expect_value(t, value(round_tripped, .P3, REC_STEER), value(original, .P3, REC_STEER))
	testing.expect_value(t, axis(round_tripped, .P3, REC_STEER), axis(original, .P3, REC_STEER))
	// ...and an action neither snapshot touched reads its zero default on both.
	testing.expect_value(t, pressed(round_tripped, .P4, REC_FIRE), false)
	testing.expect_value(t, value(round_tripped, .P4, REC_STEER), Fixed(0))
}

@(test)
test_round_trip_preserves_released_edge :: proc(t: ^testing.T) {
	// A `released` edge is set by bindings resolution but by NO producer, so the
	// round-trip must reconstruct it from the log rather than re-derive it from the
	// producer surface. Build the snapshot's tables directly to carry the edge.
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
	// The header pins the artifact identity so a replay refuses a mismatched build
	// (§09 §5). The identity is derived from the REAL golden pong artifact — the
	// content hash over the artifact bytes plus its schema/name/version/tick rate —
	// and the recorded header round-trips back to exactly that identity.
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
	// The content hash is what makes the identity build-specific: two artifacts
	// differing by a single byte hash differently, so a replay recorded against one
	// can detect it is being re-fed into the other (§09 §5). A hash that ignored the
	// bytes would silently accept a mismatched build.
	a := identity_from_program(Program{}, "funpack-artifact 1\n[meta 0]\n")
	b := identity_from_program(Program{}, "funpack-artifact 1\n[meta 1]\n")
	testing.expect(t, a.content_hash != b.content_hash)
}

@(test)
test_read_replay_refuses_wrong_magic :: proc(t: ^testing.T) {
	// The read-back fails closed on a non-replay file or a version it was not built
	// for — it never best-effort-parses a foreign log (the artifact format's
	// exact-match discipline, §1, applied to the replay log).
	_, bad_magic_ok := read_replay("notreplay 1\n[ticks 0]\n", context.temp_allocator)
	testing.expect(t, !bad_magic_ok)

	_, bad_version_ok := read_replay("funpack-replay 2\n[ticks 0]\n", context.temp_allocator)
	testing.expect(t, !bad_version_ok)
}
