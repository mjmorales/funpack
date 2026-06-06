// Yard quicksave/quickload round-trip acceptance harness (spec §24, §07 §4, §09
// §5, §28; team Lore #9). It extends the base yard golden harness
// (yard_acceptance_test.odin) with a SECOND scripted session that exercises the
// §24 persistence boundary INSIDE a recorded run: drive a crate, press F5
// (Cmd::Save = Key::F5) to quicksave the committed world, keep driving so the
// world mutates, then press F9 (Cmd::Restore = Key::F9) to quickload — and prove
// the re-fold reproduces the live capture BIT-IDENTICALLY THROUGH the save/restore
// boundary.
//
// THE LOAD-BEARING DETERMINISM MODEL — why a mid-run Restore stays re-fold-
// deterministic (the design this story surfaces and records, runtime Lore #9, the
// runtime decision restore-refolds-deterministically-slot-as-refold-function):
//
//   - §24 Save/Restore is EXPLICITLY NOT the §23.4 replay/determinism record. A
//     Replay_Log carries only identity + []Input by construction — there is no
//     field for a Save effect or a slot blob. The persistence layer never rides the
//     replay log.
//   - The F5/F9 presses ride the RECORDED INPUT STREAM exactly as any button does:
//     Cmd::Save and Cmd::Restore are Button actions, so a recording captures the
//     INPUT that triggered a save (pressed Save on tick S), never the save effect.
//   - On a re-fold the SAME F5 re-serializes the SAME committed version into the
//     SAME slot (the snapshot codec is content-hash-pinned and exact over §10
//     fixed-point), and the SAME F9 swaps that exact committed version back at the
//     next tick boundary. The slot content is therefore a deterministic FUNCTION OF
//     THE RE-FOLD, never ambient disk state — the swap presents to the frame digest
//     as the next committed version, so a recording with a mid-session Restore
//     re-folds to the same per-tick digests as the live capture.
//   - The HARNESS DRIVES A HERMETIC IN-MEMORY SLOT (new_in_memory_store): cwd-free,
//     embeddable, no disk residue — the same hand-built-fixture discipline the
//     committed golden fixtures use (team Lore #8). A temp-file slot would couple the
//     test to a writable cwd and leave residue for no determinism gain (the slot is a
//     pure function of the re-fold either way); the in-memory store is the chosen
//     backend. The real runtime path is the core:os On_Disk_Store arm (save_io.odin),
//     OUT of this acceptance scope.
//
// WHY THIS SESSION ROUTES step_tick_persist, NOT the base harness's step_tick. The
// production replay_capture / step_tick path (replay.odin) DROPS §24 persist
// commands — it folds the pipeline and commits, but never serializes a slot or
// swaps on a Restore (the persist boundary is the separate step_tick_persist driver,
// save_io.odin). The base yard session emits no persist command, so it rides the
// plain path. THIS session's whole point is the persist boundary, so its live
// capture AND its re-fold both drive step_tick_persist over a FRESH in-memory store —
// the persist-aware twin of refold_capture, identical but for engaging the §24
// boundary. The re-fold re-feeds the recorded log's Input snapshots through that same
// driver, so the only substitution is the input source (live snapshot vs parsed log),
// exactly as the base harness's substitution — the bit-identity that proves the
// slot-as-input model holds.
//
// THE ROUND-TRIP THE DIGEST FOLDS (the observable mutation that makes the probe
// non-vacuous): yard_save_session_inputs maneuvers the Player over the center crate
// (spawn (80,40)) and pushes it down in TWO phases, settling to REST between them.
// At YARD_SAVE_TICK the world is at rest position A; F5 quicksaves it. The session
// then pushes the crate FURTHER to a distinct rest position B and presses F9 at
// YARD_RESTORE_TICK. At YARD_RESTORE_TICK+1 the swap takes effect — the committed
// world folds from the RESTORED tick-S version, so the crate reverts to rest A
// (test_yard_save_session_round_trips_at_restore_boundary pins crate(R+1) == crate(S)
// and Scoreboard.delivered(R+1) == delivered(S)). The crate at rest is the load-
// bearing revert: a resting restored world folded forward one brake tick stays put,
// so the revert is bit-exact (no delivery is needed, only visible mutation — Lore #9
// note: the replay log is not the save layer, the round-trip is proven on the digest).
//
// GOLDEN-FIXTURE REGENERATION (rebuild the committed save log + expected digest):
//
//     FUNPACK_REGEN_GOLDEN=1 task -d runtime test
//
// arms test_regenerate_yard_save_golden_fixtures (the SAME env gate the base harness
// uses) — it records yard_save_session_inputs through the production recorder, writes
// testdata/yard_save_golden.replay, re-folds it through the persist-aware driver, and
// writes the produced session digest to testdata/yard_save_golden.digest. Commit both.
// Regenerate ONLY on a deliberate artifact/codec/encoding change that intentionally
// moves the digest — a digest that moves without one is a determinism regression.
//
// OPERATOR GATE — second-machine / second-build reproduction (verifies_by:gate): on a
// second machine or an independently rebuilt binary, run `task -d runtime test` and
// confirm test_committed_yard_save_log_reproduces_expected_digest PASSES — it re-folds
// the COMMITTED testdata/yard_save_golden.replay (F5/F9-bearing) through the persist
// boundary and asserts its session digest equals the committed expected digest, so a
// passing run is a bit-identical reproduction of the save/restore round-trip.
package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

// YARD_SAVE_GOLDEN_REPLAY_LOG is the committed F5/F9-bearing golden save log,
// embedded at compile time — so the cross-build re-fold runs with no filesystem and
// no cwd, only the runtime package. It is the byte-stable log yard_save_session_inputs
// records through the production recorder; the regeneration test rewrites it.
YARD_SAVE_GOLDEN_REPLAY_LOG := #load("testdata/yard_save_golden.replay", string)

// YARD_SAVE_GOLDEN_EXPECTED_DIGEST is the committed expected session digest of the
// save log's PERSIST-AWARE re-fold, a decimal u64 text fixture. A build that re-folds
// YARD_SAVE_GOLDEN_REPLAY_LOG through step_tick_persist must reproduce exactly this
// value; a divergence is the §24-on-the-determinism-target proof failing, not a stale
// fixture.
YARD_SAVE_GOLDEN_EXPECTED_DIGEST := #load("testdata/yard_save_golden.digest", string)

// YARD_SAVE_BTN / YARD_RESTORE_BTN are the Cmd::Save / Cmd::Restore Button ActionIds
// the registry mints from yard's enum walk. yard.fun declares `enum Drive: Axis
// { Move }` first (Move = ActionId 0, the base harness's YARD_MOVE), then `enum Cmd:
// Button { Save, Restore, ToggleMotion, Apply }` — so the Cmd buttons mint 1..4 in
// variant order: Save = 1, Restore = 2. These are the F5/F9 presses (yard.fun
// bindings: Cmd::Save = Key::F5, Cmd::Restore = Key::F9) the scripted session rides on
// the recorded INPUT stream — the slot-as-input model rests on these being plain
// recorded button actions.
@(private = "file")
YARD_SAVE_BTN :: ActionId(1)
@(private = "file")
YARD_RESTORE_BTN :: ActionId(2)

// YARD_SAVE_MOVE is yard's Drive::Move axis action — ActionId 0, the same axis the
// base harness drives the Player through. Declared file-locally (the base harness's
// YARD_MOVE is file-private to that file), so the two definitions never collide.
@(private = "file")
YARD_SAVE_MOVE :: ActionId(0)

// YARD_SAVE_SESSION_TICKS is the scripted save session length: long enough to push
// the crate to rest A, quicksave, push it to a distinct rest B, quickload, and run a
// post-restore tail so the digest folds the swap plus distinct decay frames. Kept
// SHORT (no delivery needed — only visible mutation between save and restore, Lore #9).
@(private = "file")
YARD_SAVE_SESSION_TICKS :: 270

// YARD_SAVE_TICK is the tick the F5 quicksave fires (Cmd::Save pressed). The world is
// at REST position A here (the phase-1 push has settled), so the committed snapshot is
// a stable checkpoint the restore reverts to. A resting save point is what makes the
// round-trip revert bit-exact: folding the restored world forward one brake tick
// leaves the crate put.
@(private = "file")
YARD_SAVE_TICK :: 140

// YARD_RESTORE_TICK is the tick the F9 quickload fires (Cmd::Restore pressed), R > S.
// The world is at REST position B here (the phase-2 push has settled past A), so the
// mutation between save and restore is visible in the committed crate position. The
// swap takes effect at YARD_RESTORE_TICK+1 (§24: Restore swaps at the boundary, not
// mid-tick), reverting the crate to rest A.
@(private = "file")
YARD_RESTORE_TICK :: 248

// yard_save_session_inputs builds the F5/F9-bearing scripted session the save golden
// fixtures are generated from and the live-vs-refold test drives. It reuses the base
// session's push geometry (the Player spawns BELOW the center crate, so it clears the
// column, rises above, recenters over x=80, and pushes DOWN) but SHORTER, in two push
// phases settling to rest between them: phase 1 settles to rest A (F5 quicksave at
// YARD_SAVE_TICK), phase 2 pushes to a distinct rest B (F9 quickload at
// YARD_RESTORE_TICK). The Save/Restore presses ride ON the brake axis at those ticks
// (with_pressed over a brake with_axis), so the same recorded snapshot carries both
// the (zero) move axis and the button edge. The SAME slice drives the live capture,
// the recorded re-fold, and the regeneration, so the three stay reproducible from this
// one definition.
yard_save_session_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, YARD_SAVE_SESSION_TICKS, allocator)
	up := Vec2{Fixed(0), fixed_neg(to_fixed(1))}
	down := Vec2{Fixed(0), to_fixed(1)}
	left := Vec2{fixed_neg(to_fixed(1)), Fixed(0)}
	right := Vec2{to_fixed(1), Fixed(0)}
	brake := VEC2_ZERO

	Leg :: struct {
		axis:  Vec2,
		ticks: int,
	}
	// Each leg is (axis, tick-count); they concatenate into the session. The leg
	// boundaries place YARD_SAVE_TICK in the phase-1 settle (crate at rest A) and
	// YARD_RESTORE_TICK in the phase-2 settle (crate at rest B), both brake ticks.
	legs := []Leg {
		{left, 12}, {right, 12}, {brake, 4}, // clear left of the crate column, brake
		{up, 18}, {down, 18}, {brake, 4}, // rise above the crate top, brake
		{right, 12}, {left, 12}, {brake, 8}, // recenter exactly over x=80, brake
		{down, 20}, {brake, 30}, // PHASE 1: push to rest A — F5 quicksave at tick 140
		{up, 16}, {down, 16}, {brake, 4}, // recover above the crate
		{down, 24}, {brake, 60}, // PHASE 2: push to rest B, then F9 at 248 + tail
	}

	tick := 0
	for leg in legs {
		for _ in 0 ..< leg.ticks {
			if tick >= YARD_SAVE_SESSION_TICKS {
				return inputs
			}
			inputs[tick] = with_axis(empty(), .P1, YARD_SAVE_MOVE, leg.axis)
			tick += 1
		}
	}
	for tick < YARD_SAVE_SESSION_TICKS {
		inputs[tick] = with_axis(empty(), .P1, YARD_SAVE_MOVE, brake)
		tick += 1
	}

	// Ride the F5/F9 presses on the recorded INPUT stream: the same snapshot at S/R
	// carries the brake move axis AND the Save/Restore button edge — a plain recorded
	// button action, the slot-as-input model's premise.
	inputs[YARD_SAVE_TICK] = with_pressed(inputs[YARD_SAVE_TICK], .P1, YARD_SAVE_BTN)
	inputs[YARD_RESTORE_TICK] = with_pressed(inputs[YARD_RESTORE_TICK], .P1, YARD_RESTORE_BTN)
	return inputs
}

// yard_save_capture drives a yard save session through step_tick_persist over a FRESH
// hermetic in-memory store, capturing each committed tick's frame digest over the
// world state and its §20 draw-list (the SAME digest surface the base harness uses).
// It is the persist-aware twin of refold_capture (replay.odin): identical setup +
// render-digest seam, but routing the §24 persist boundary so an F5 serializes the
// committed checkpoint and an F9 swaps it back. The store is FRESH per call so two
// captures never share ambient disk state — the slot content is a pure function of
// THIS run's fold, the slot-as-input model the bit-identity check proves. Yard is
// SEEDLESS: no Rng is threaded.
@(private = "file")
yard_save_capture :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> Frame_Capture {
	store := new_in_memory_store(allocator)
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	carrier := new_persist_carrier(&store)
	time := yard_time(program.entrypoint.tick_hz, allocator)
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	for input in inputs {
		version, carrier = step_tick_persist(program, version, input, time, carrier, allocator)
		draw := render_version(program, version, input, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}

// yard_save_refold_capture re-folds a PARSED log's recorded snapshots through the same
// persist-aware driver yard_save_capture uses, gated FIRST by the identity check (a
// mismatched build is refused before any tick). It is the consuming twin of the live
// capture: it re-feeds the parsed Input stream (carrying the recorded F5/F9 edges)
// instead of the live scripted snapshots, the ONLY substitution — so a bit-identical
// re-fold proves the slot is re-serialized deterministically from the same committed
// version and the swap reproduces. Returns the refusal arm so a build mismatch fails
// closed rather than silently re-folding the wrong artifact.
@(private = "file")
yard_save_refold_capture :: proc(
	program: ^Program,
	artifact_bytes: string,
	log: Replay_Log,
	allocator := context.allocator,
) -> (
	capture: Frame_Capture,
	refusal: Replay_Refusal,
) {
	loaded_identity := identity_from_program(program^, artifact_bytes)
	if !yard_save_identity_matches(log.identity, loaded_identity) {
		return {}, .Identity_Mismatch
	}
	return yard_save_capture(program, log.snapshots, allocator), .None
}

// yard_save_identity_matches gates the save-session re-fold on the SAME seedless build
// fingerprint the production replay gate checks: schema version, §4 project name and
// version, fixed tick rate, and the xxh64 content hash over the raw artifact bytes.
// Yard is seedless (no RNG, no seed, Lore #9), so the seed is fixed false on both
// sides — a recorded log against this build matches, a foreign build is refused.
@(private = "file")
yard_save_identity_matches :: proc(recorded, loaded: Replay_Identity) -> bool {
	return(
		recorded.artifact_schema_version == loaded.artifact_schema_version &&
		recorded.project_name == loaded.project_name &&
		recorded.project_version == loaded.project_version &&
		recorded.tick_hz == loaded.tick_hz &&
		recorded.content_hash == loaded.content_hash &&
		!recorded.has_seed &&
		!loaded.has_seed \
	)
}

// record_yard_save_session records the F5/F9-bearing scripted session through the
// production recorder against the golden yard artifact's pinned seedless identity and
// returns the finished log bytes — the byte-stable record both the live-vs-refold test
// re-folds and the regeneration test persists. Mirrors the base harness's
// record_yard_session: only the input session differs (this one carries the persist
// presses).
@(private = "file")
record_yard_save_session :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> string {
	identity := identity_from_program(program^, YARD_ARTIFACT)
	writer := open_replay_writer(identity, allocator)
	defer delete_replay_writer(&writer)
	for input in inputs {
		record_tick(&writer, input, allocator)
	}
	return finish_replay(&writer, allocator)
}

@(test)
test_yard_save_live_run_and_refold_have_identical_digests :: proc(t: ^testing.T) {
	// A live yard save run and the re-fold of its RECORDED log yield bit-identical
	// per-tick AND session frame digests THROUGH the F5 save + F9 restore boundary
	// (§24, §07 §4, Lore #9). Both captures route step_tick_persist over a FRESH
	// in-memory store and share only the artifact + the recorded snapshots — the
	// re-fold substitutes nothing but the input source — so equal per-tick digests
	// prove every committed tick matched INCLUDING the swap tick (YARD_RESTORE_TICK+1,
	// where the restored world becomes the committed version the digest reads). This is
	// the PROOF the slot-as-input model holds: the same F5 re-serialized the same
	// committed version, the same F9 swapped it back, and the re-fold reproduced both.
	context.allocator = context.temp_allocator

	live_program, ok := load_yard(t)
	if !ok {
		return
	}
	inputs := yard_save_session_inputs()
	live := yard_save_capture(&live_program, inputs)

	// Record the scripted session, then read it back through the production parser —
	// the re-fold re-feeds these parsed snapshots (carrying the F5/F9 edges).
	log_bytes := record_yard_save_session(&live_program, inputs)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}
	// The recorded log is identity + []Input — the F5/F9 presses survive as INPUT, no
	// persist effect rode the log (the §24-is-not-the-replay-record property, Lore #9).
	testing.expect(t, pressed(log.snapshots[YARD_SAVE_TICK], .P1, YARD_SAVE_BTN))
	testing.expect(t, pressed(log.snapshots[YARD_RESTORE_TICK], .P1, YARD_RESTORE_BTN))

	// Re-fold against a FRESH program load through the persist-aware capturing driver.
	refold_program, refold_ok := load_yard(t)
	if !refold_ok {
		return
	}
	refold, refusal := yard_save_refold_capture(&refold_program, YARD_ARTIFACT, log)
	if !testing.expect_value(t, refusal, Replay_Refusal.None) {
		return
	}

	if !testing.expect_value(t, len(refold.per_tick), len(live.per_tick)) {
		return
	}
	for frame, i in live.per_tick {
		testing.expect_value(t, refold.per_tick[i].tick, frame.tick)
		testing.expect_value(t, refold.per_tick[i].digest, frame.digest)
	}
	testing.expect_value(t, refold.session, live.session)
}

@(test)
test_committed_yard_save_log_reproduces_expected_digest :: proc(t: ^testing.T) {
	// The COMMITTED F5/F9-bearing save log, re-folded on the CURRENT build through the
	// persist boundary, produces a session digest exactly equal to the COMMITTED
	// expected digest fixture (§24, §09 §5, §28). The cross-build two-machine proxy
	// for the save/restore round-trip: Input is the sole recorded nondeterminism source
	// (yard is seedless, the F5/F9 presses are recorded input, the slot is a function of
	// the re-fold — Lore #9), so a DIFFERENT build re-folding this SAME committed log
	// must reproduce this SAME digest. A divergence is the §24-on-the-determinism-target
	// failing, not a stale fixture.
	context.allocator = context.temp_allocator

	program, ok := load_yard(t)
	if !ok {
		return
	}

	log, parse_ok := read_replay(YARD_SAVE_GOLDEN_REPLAY_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}

	refold, refusal := yard_save_refold_capture(&program, YARD_ARTIFACT, log)
	if !testing.expect_value(t, refusal, Replay_Refusal.None) {
		return
	}

	expected, digest_ok := parse_yard_save_committed_digest(YARD_SAVE_GOLDEN_EXPECTED_DIGEST)
	if !testing.expect(t, digest_ok) {
		return
	}
	testing.expect_value(t, refold.session, expected)
}

@(test)
test_yard_save_session_round_trips_at_restore_boundary :: proc(t: ^testing.T) {
	// The round-trip PROBE: at YARD_RESTORE_TICK+1 the committed world re-converges to
	// the saved (YARD_SAVE_TICK) committed state — the crate back at its tick-S position
	// and Scoreboard.delivered back to its tick-S count — proving the F9 quickload
	// actually swapped the saved version back (§24: Restore swaps at the boundary). It
	// drives the SAME yard_save_session_inputs through step_tick_persist, snapshotting
	// the committed crate position + delivered count at S, at R (mutated — the crate
	// pushed past where it was saved, the guard the bit-identity check would miss if the
	// restore were a no-op), and at R+1 (reverted). The crate position is the load-
	// bearing revert; the tick ordinal at R+1 is S+1 (the restored world folded forward
	// one boundary tick), so the digest is NOT identical to S's — the WORLD STATE is what
	// round-trips, which is what §24 guarantees.
	context.allocator = context.temp_allocator

	program, ok := load_yard(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	version := run_startup(&program, initial_version(world, context.temp_allocator))
	time := yard_time(program.entrypoint.tick_hz)
	inputs := yard_save_session_inputs()

	store := new_in_memory_store()
	carrier := new_persist_carrier(&store)

	saved_crate: Vec2
	saved_delivered: i64
	mutated_crate: Vec2
	reverted_crate: Vec2
	reverted_delivered: i64
	for input, i in inputs {
		version, carrier = step_tick_persist(&program, version, input, time, carrier)
		if i == YARD_SAVE_TICK {
			saved_crate = yard_save_center_crate_pos(&version)
			saved_delivered = yard_save_scoreboard_delivered(&version)
		}
		if i == YARD_RESTORE_TICK {
			mutated_crate = yard_save_center_crate_pos(&version)
		}
		if i == YARD_RESTORE_TICK + 1 {
			reverted_crate = yard_save_center_crate_pos(&version)
			reverted_delivered = yard_save_scoreboard_delivered(&version)
		}
	}

	// Between save and restore the crate MUST have moved — else a no-op restore would
	// pass the revert check vacuously. The phase-2 push settled the crate past rest A.
	testing.expect(t, mutated_crate != saved_crate)

	// At the restore boundary the crate reverts to its tick-S position and the tally
	// reverts to its tick-S count — the world round-tripped through the quickload.
	testing.expect_value(t, reverted_crate, saved_crate)
	testing.expect_value(t, reverted_delivered, saved_delivered)
}

@(test)
test_regenerate_yard_save_golden_fixtures :: proc(t: ^testing.T) {
	// Regeneration is armed only by FUNPACK_REGEN_GOLDEN (the SAME gate the base
	// harness uses) — a normal `task test` SKIPS this, so the committed save fixtures
	// are never silently rewritten. When armed, it records the F5/F9-bearing session
	// through the production recorder, writes the byte-stable log to
	// testdata/yard_save_golden.replay, re-folds it through the PERSIST-AWARE driver,
	// and writes the produced session digest to testdata/yard_save_golden.digest — both
	// relative to the runtime/ cwd `task -d runtime test` runs from. Commit both.
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) == "" {
		return
	}
	context.allocator = context.temp_allocator

	program, ok := load_yard(t)
	if !ok {
		return
	}
	inputs := yard_save_session_inputs()
	log_bytes := record_yard_save_session(&program, inputs)

	log_path, log_join_err := filepath.join({"testdata", "yard_save_golden.replay"})
	if !testing.expect(t, log_join_err == nil) {
		return
	}
	if !testing.expect(t, write_replay_file(log_path, log_bytes)) {
		return
	}

	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}
	refold, refusal := yard_save_refold_capture(&program, YARD_ARTIFACT, log)
	if !testing.expect_value(t, refusal, Replay_Refusal.None) {
		return
	}

	digest_buf: [20]byte
	digest_text := strconv.write_uint(digest_buf[:], refold.session, 10)
	digest_path, digest_join_err := filepath.join({"testdata", "yard_save_golden.digest"})
	if !testing.expect(t, digest_join_err == nil) {
		return
	}
	testing.expect(t, os.write_entire_file_from_string(digest_path, digest_text) == nil)
}

// parse_yard_save_committed_digest reads the committed expected-digest fixture — a
// decimal u64 with any trailing newline trimmed — into its u64 value. A bare decimal
// so a human can read the committed digest at a glance and a regeneration writes it
// back the same way; ok is false on a malformed fixture so the test fails closed. (The
// base harness's parse_yard_committed_digest is file-private to that file, so this file
// carries its own copy — the same trim-and-parse the base fixture uses.)
@(private = "file")
parse_yard_save_committed_digest :: proc(text: string) -> (digest: u64, ok: bool) {
	trimmed := strings.trim_space(text)
	return strconv.parse_u64(trimmed)
}

// yard_save_center_crate_pos reads the CENTER crate's committed `pos` Vec2 — the crate
// the Player pushes (spawn (80,40), the second of the three crates in ascending Id
// order, so rows[1]). It is the round-tripping state: at rest before/after a push, and
// reverted to its tick-S position at the restore boundary. An absent table/row or a
// non-Vec2 column yields the zero vector so the probe fails closed.
@(private = "file")
yard_save_center_crate_pos :: proc(version: ^World_Version) -> Vec2 {
	table := version_find_table(version, "Crate")
	if table == nil || len(table.rows) < 2 {
		return VEC2_ZERO
	}
	pos, ok := table.rows[1].fields["pos"].(Vec2)
	if !ok {
		return VEC2_ZERO
	}
	return pos
}

// yard_save_scoreboard_delivered reads the Scoreboard singleton's `delivered` Int — the
// tally the restore reverts alongside the crate position. An absent table/row or a
// non-Int column yields -1 so the probe fails closed rather than comparing against a
// zero default.
@(private = "file")
yard_save_scoreboard_delivered :: proc(version: ^World_Version) -> i64 {
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
