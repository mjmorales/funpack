// Replay re-fold acceptance (spec §07 §4, §09 §5, §23 §4): the driver restarts
// the golden pong artifact and re-feeds a recorded snapshot stream over the SAME
// tick loop a live run uses, committing a world bit-identical to the original
// run's. The tests prove the two load-bearing guarantees against the REAL golden
// program — not a hand-built stand-in:
//
//   - a recorded session re-folds tick-by-tick to the recorded tick count,
//     supplying the recorded Input each tick, and the world it commits is
//     bit-identical to the original run's (world_versions_equal) — the only
//     substitution is the input source, so the replay reproduces the run exactly;
//   - a log whose pinned artifact hash differs from the loaded artifact is REFUSED
//     with a diagnostic (Replay_Refusal.Identity_Mismatch), not silently re-folded
//     against the wrong build (§09 §5).
//
// The snapshot stream is built in the device-free producer vocabulary (input.odin)
// — RAW device state never appears — and recorded through the production recorder,
// so the replay exercises the recorder → reader → driver path end to end.
package funpack_runtime

import "core:testing"

// REPLAY_TICK_COUNT is the recorded session length: long enough that the ball
// crosses the board edge and serves (the scoring + serve + signal-route paths
// fold), so the replay reproduces a non-trivial run, not a straight-line advance.
@(private = "file")
REPLAY_TICK_COUNT :: 600

// replay_input_at builds the recorded snapshot for one tick of the session: P1
// holds Steer::Move at +1 for the first stretch, then releases it — a sequence
// that moves the left paddle and then lets it sit, so the recorded stream is not a
// single constant snapshot. Steer::Move is the program's sole Axis action, minted
// as ActionId 0 (the first Axis variant in the declaration walk), matching the
// tick-fold determinism fixture. Built on the supplied allocator so the snapshot
// shares the fold/record lifetime.
@(private = "file")
replay_input_at :: proc(tick: int, allocator: Runtime_Allocator) -> Input {
	context.allocator = allocator
	if tick < REPLAY_TICK_COUNT / 2 {
		return with_value(empty(), .P1, ActionId(0), to_fixed(1))
	}
	return empty()
}

// replay_time builds the Time resource the original live fold steps at — the one
// `dt` field at the golden's fixed tick rate (1/tick_hz), the same value the
// replay driver derives. Sharing the derivation is what makes the original run and
// the re-fold step at identical dt, so any divergence is the input source, not the
// clock.
@(private = "file")
replay_time :: proc(tick_hz: int, allocator: Runtime_Allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(i64(tick_hz)))
	return Record_Value{type_name = "Time", fields = fields}
}

// run_live folds the recorded input sequence over the live tick loop — the
// ORIGINAL run the replay must reproduce. It restarts from setup (run_startup) and
// drives step_tick once per tick with the snapshot replay_input_at produces, the
// same seam the replay driver re-folds; the world it returns is the ground truth
// the bit-identity assertion compares against.
@(private = "file")
run_live :: proc(
	program: ^Program,
	tick_count: int,
	allocator := context.allocator,
) -> World_Version {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	time := replay_time(program.entrypoint.tick_hz, allocator)
	for tick in 0 ..< tick_count {
		snapshot := replay_input_at(tick, allocator)
		version = step_tick(program, version, snapshot, time, allocator)
	}
	return version
}

// record_session records the SAME input sequence run_live folds into a replay log
// through the production recorder, returning the finished log bytes. The header
// pins the golden's identity (derived from the real artifact bytes), so the log a
// replay re-feeds is the exact byte-stable record the recorder produces.
@(private = "file")
record_session :: proc(
	program: ^Program,
	tick_count: int,
	allocator := context.allocator,
) -> string {
	identity := identity_from_program(program^, GOLDEN_ARTIFACT)
	writer := open_replay_writer(identity, allocator)
	defer delete_replay_writer(&writer)
	for tick in 0 ..< tick_count {
		snapshot := replay_input_at(tick, allocator)
		record_tick(&writer, snapshot, allocator)
	}
	return finish_replay(&writer, allocator)
}

@(test)
test_replay_refolds_to_bit_identical_world :: proc(t: ^testing.T) {
	// A recorded pong session re-folds tick-by-tick to the recorded tick count,
	// supplying the recorded Input each tick, and the world it commits is
	// bit-identical to the original run's (§07 §4, §23 §4). The original run and the
	// replay share only the artifact and the recorded snapshots — the replay
	// substitutes nothing but the input source — so equality proves the re-fold
	// reproduces the run.
	program, ok := load_golden(t)
	if !ok {
		return
	}

	original := run_live(&program, REPLAY_TICK_COUNT, context.temp_allocator)

	log_bytes := record_session(&program, REPLAY_TICK_COUNT, context.temp_allocator)
	log, parse_ok := read_replay(log_bytes, context.temp_allocator)
	if !testing.expect(t, parse_ok) {
		return
	}

	// The driver re-folds the parsed log against the freshly-loaded artifact.
	result := replay(&program, GOLDEN_ARTIFACT, log, context.temp_allocator)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	// The replay reached the recorded tick count: run_startup commits the populated
	// base as version tick 0, then each of the N recorded snapshots commits one more
	// version, so the final committed ordinal is the tick count.
	testing.expect_value(t, result.world.tick, REPLAY_TICK_COUNT)

	// The replayed world is bit-identical to the original run's — same tick, same
	// rows in stable Id order, same fixed-point bits.
	testing.expect(t, world_versions_equal(result.world, original))

	// The session is non-trivial: the ball crossed the edge and scored, so the
	// scoring + serve + signal-route paths folded in both the live run and the
	// replay, not just a straight-line ball advance.
	scoreboard, _ := view_at(view_of_type(&result.world, "Scoreboard"), 0)
	left, _ := row_field(scoreboard, "left")
	right, _ := row_field(scoreboard, "right")
	testing.expect(t, left.(i64) + right.(i64) > 0)
}

@(test)
test_replay_refuses_header_hash_mismatch :: proc(t: ^testing.T) {
	// A replay log whose pinned artifact hash differs from the loaded artifact is
	// REFUSED with a diagnostic, not silently re-folded against the wrong build
	// (§09 §5). The log here carries the golden's schema/name/version/tick rate but
	// a content hash from a DIFFERENT build, so only the content-hash field diverges
	// — the gate must still fire, since the hash is the build-specific fingerprint.
	program, ok := load_golden(t)
	if !ok {
		return
	}

	matching := identity_from_program(program, GOLDEN_ARTIFACT)
	// A log recorded against a one-byte-different artifact: every identity field
	// matches the golden EXCEPT the content hash, which is the build fingerprint.
	mismatched := matching
	mismatched.content_hash = matching.content_hash ~ 0x1

	writer := open_replay_writer(mismatched, context.temp_allocator)
	defer delete_replay_writer(&writer)
	snap := with_value(empty(), .P1, ActionId(0), to_fixed(1))
	defer delete_input(snap)
	record_tick(&writer, snap, context.temp_allocator)
	log_bytes := finish_replay(&writer, context.temp_allocator)

	log, parse_ok := read_replay(log_bytes, context.temp_allocator)
	if !testing.expect(t, parse_ok) {
		return
	}

	// replay(artifact_A, log_with_hash_B) refuses with Identity_Mismatch rather than
	// re-folding the recorded snapshot over the wrong program.
	result := replay(&program, GOLDEN_ARTIFACT, log, context.temp_allocator)
	testing.expect_value(t, result.refusal, Replay_Refusal.Identity_Mismatch)

	// The refusal carries a diagnostic naming the mismatch, and folds NO tick — the
	// returned world is the empty zero value, never a partial re-fold.
	testing.expect(t, len(result.diagnostic) > 0)
	testing.expect_value(t, result.world.tick, 0)
	testing.expect_value(t, len(result.world.tables), 0)
}
