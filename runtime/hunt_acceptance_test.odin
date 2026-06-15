// Hunt two-machine bit-identity acceptance harness (spec §07 §4, §09 §5, §20,
// §28): the determinism floor pong established, now extended to hunt — the
// MULTI-THING, read-side-View, NO-RNG AI surface (Lore #7, #8). It proves, end to
// end and against the REAL golden hunt artifact, the SAME three properties the
// pong acceptance harness rests on, against a scripted session that cycles a
// Hunter through every AI state so the digest folds every match arm:
//
//   - LIVE-VS-REPLAY BIT-IDENTITY: a live hunt run captured per-tick (the digest
//     surface) and the production re-fold of its RECORDED log, captured the same
//     way through the same identity-gated replay_capture driver, produce
//     bit-identical per-tick AND session frame digests — the digest reads committed
//     state, so substituting the input source (live resolution vs the recorded
//     snapshot) changes nothing in the digests (§07 §4);
//   - CROSS-BUILD GOLDEN RE-FOLD: a golden replay log committed under testdata/,
//     re-folded on the CURRENT build, reproduces the committed expected session
//     digest bit-identically — the honest, CI-runnable mechanical proxy for
//     "identical on a second machine", since a different build re-folding the same
//     committed log must reproduce the same committed digest (§09 §5 interpreter-as-
//     ground-truth: input is the SOLE nondeterminism source — hunt is SEEDLESS,
//     no RNG, no seed (Lore #7) — so the committed log plus the committed digest
//     are the durable milestone regression fixtures);
//   - GATE REPRODUCTION RECIPE: a true cross-hardware/second-build run is
//     operator-gated, not CI-mechanizable — the operator runs the same golden
//     re-fold on a second machine or an independently rebuilt binary and confirms
//     the produced session digest equals the committed expected digest. The
//     GOLDEN-FIXTURE REGENERATION + OPERATOR GATE recipe below documents both the
//     regeneration command and the exact reproduction command.
//
// THE AI CYCLE THE DIGEST FOLDS (the non-trivial shape that makes the per-tick
// digests distinct and exercises every think arm): the scripted session
// (hunt_session_inputs) drives P1's Drive::Move 2D axis to walk the Player from
// its spawn (80,100) toward Hunter id=0 (spawn (40,40), SIGHT=30), then away and
// out of sight for longer than SEARCH_TIME (2.0s). Hunter id=0 cycles
// Patrol -> Chase -> Search -> Patrol. The transition tick indices, asserted
// exactly by test_scripted_session_cycles_hunter_ai, are stable arithmetic over
// the Q32.32 kernel (no float, Lore #7):
//
//   tick   0 : Patrol (the spawn default =Hunt::Patrol applied at setup)
//   tick  23 : Patrol -> Chase  (Player closes within SIGHT=30 of (40,40))
//   tick  75 : Chase  -> Search (Player escapes sight; search_t armed to 2.0s)
//   tick 196 : Search -> Patrol (search_t counts down 2.0s = 120 ticks to <= 0)
//
// so per-tick states span Patrol[0,22] Chase[23,74] Search[75,195] Patrol[196,239]
// across the HUNT_SESSION_TICKS-tick session — every think arm AND every
// hunter_color render arm (Green/Red/White) folds into the digest.
//
// GOLDEN-FIXTURE REGENERATION (rebuild the committed log + expected digest):
//
//     FUNPACK_REGEN_GOLDEN=1 task -d runtime test
//
// That env var arms test_regenerate_hunt_golden_fixtures, which records the
// scripted session (hunt_session_inputs) through the production recorder against
// the golden hunt artifact's pinned identity, writes the byte-stable log to
// testdata/hunt_golden.replay, re-folds it through replay_capture, and writes the
// produced session digest (decimal u64) to testdata/hunt_golden.digest. Commit
// both regenerated files. Regenerate ONLY when a deliberate change to the artifact,
// the replay encoding, or the frame-digest encoding intentionally moves the digest
// — a digest that moves without such a change is a determinism regression, not a
// stale fixture.
//
// OPERATOR GATE — second-machine / second-build reproduction (verifies_by:gate):
// on a second machine, or against an independently rebuilt binary, run
//
//     task -d runtime test
//
// and confirm test_committed_hunt_log_reproduces_expected_digest PASSES. That test
// re-folds the COMMITTED testdata/hunt_golden.replay on the build under test and
// asserts its session digest equals the COMMITTED testdata/hunt_golden.digest — so
// a passing run on the second machine is a bit-identical reproduction of the
// committed digest. The committed fixtures are embedded with #load, so the
// reproduction needs no funpack source and no cwd — only the runtime package and
// the committed testdata/.
package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

// HUNT_ARTIFACT is the committed golden hunt artifact, embedded at compile time
// the same hermetic way GOLDEN_ARTIFACT (pong) is — a byte-identical copy of the
// compiler-emitted golden at examples/hunt/.funpack/artifact. It is
// the ONE story that consumes the emitted artifact (Lore #7, #8): runtime does
// NOT define the artifact format, it executes these bytes.
HUNT_ARTIFACT := #load("testdata/hunt.artifact", string)

// HUNT_GOLDEN_REPLAY_LOG is the committed golden hunt replay log, embedded at
// compile time — so the cross-build re-fold test runs with no filesystem and no
// cwd, only the runtime package. It is the byte-stable log hunt_session_inputs
// records through the production recorder; the regeneration test rewrites this
// file from the embedded artifact.
HUNT_GOLDEN_REPLAY_LOG := #load("testdata/hunt_golden.replay", string)

// HUNT_GOLDEN_EXPECTED_DIGEST is the committed expected session digest of the
// hunt golden log's re-fold, embedded as a decimal u64 text fixture. A build that
// re-folds HUNT_GOLDEN_REPLAY_LOG must reproduce exactly this value; a divergence
// is the determinism target failing, not a stale fixture.
HUNT_GOLDEN_EXPECTED_DIGEST := #load("testdata/hunt_golden.digest", string)

// HUNT_SESSION_TICKS is the scripted session length: long enough that Hunter
// id=0 cycles Patrol -> Chase -> Search -> Patrol (the last transition lands at
// tick 196), with a tail in the final Patrol state so the digest folds distinct
// per-tick frames in every AI arm — the same non-trivial evolving shape pong's
// serve path gives.
@(private = "file")
HUNT_SESSION_TICKS :: 240

// HUNT_MOVE is hunt's Drive::Move axis action — ActionId 0, the sole Axis variant
// in the declaration walk. The scripted session drives the Player through it on
// both components (a 2D axis via with_axis), so the Player walks diagonally toward
// then away from the Hunter and the committed state evolves tick to tick.
@(private = "file")
HUNT_MOVE :: ActionId(0)

// HUNT_TOWARD_TICKS is how long the scripted session drives the Player TOWARD the
// Hunter before reversing: long enough that the Player crosses within SIGHT=30 of
// Hunter id=0 (triggering Patrol -> Chase at tick 23), after which the reversal
// walks it back out of sight (triggering Chase -> Search then the timed
// Search -> Patrol). 40 ticks leaves the Player deep enough inside SIGHT that the
// approach is unambiguous before the reversal.
@(private = "file")
HUNT_TOWARD_TICKS :: 40

// Asserted AI-transition tick indices for Hunter id=0 under hunt_session_inputs —
// stable arithmetic over the Q32.32 kernel (no float, Lore #7). A change here is a
// determinism regression unless a deliberate artifact/encoding change moved it.
@(private = "file")
HUNT_CHASE_TICK :: 23 // Patrol -> Chase: Player within SIGHT=30
@(private = "file")
HUNT_SEARCH_TICK :: 75 // Chase -> Search: Player out of sight, search_t armed
@(private = "file")
HUNT_PATROL_TICK :: 196 // Search -> Patrol: search_t counted down 2.0s to <= 0

// hunt_session_inputs builds the scripted input session the golden fixtures are
// generated from and the live-vs-replay test drives: P1 holds Drive::Move at
// (-1,-1) for the first HUNT_TOWARD_TICKS ticks (walking the Player diagonally
// toward Hunter id=0 at (40,40)), then (+1,+1) for the rest (walking it away and
// out of sight past SEARCH_TIME). The SAME sequence drives the live capture and is
// recorded for the re-fold, so the two captures must agree; it is also the sole
// source the committed golden log is regenerated from, so the fixtures stay
// reproducible from this one definition.
@(private = "file")
hunt_session_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, HUNT_SESSION_TICKS, allocator)
	toward := Vec2{fixed_neg(to_fixed(1)), fixed_neg(to_fixed(1))}
	away := Vec2{to_fixed(1), to_fixed(1)}
	for i in 0 ..< HUNT_SESSION_TICKS {
		axis := i < HUNT_TOWARD_TICKS ? toward : away
		inputs[i] = with_axis(empty(), .P1, HUNT_MOVE, axis)
	}
	return inputs
}

// hunt_time binds the captures' Time through the ONE shared dt derivation
// (replay.odin's time_resource) — the same proc the re-fold binds through, so
// the two cannot fork and any digest divergence is the input source, not the
// clock.
@(private = "file")
hunt_time :: proc(tick_hz: int, allocator := context.allocator) -> Record_Value {
	return time_resource(tick_hz, allocator)
}

// load_hunt parses the embedded hunt fixture into a Program against the test's
// temp allocator, failing the test on any refusal — the hunt counterpart of
// load_golden (pong).
@(private = "file")
load_hunt :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(HUNT_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "golden hunt artifact must load, got %v", err) {
		return {}, false
	}
	return loaded, true
}

// hunt_live_capture drives a golden hunt session LIVE — restarting from setup and
// stepping the tick loop once per scripted input — capturing each committed tick's
// frame digest over the world state and its §20 draw-list, then folding the session
// digest. It is the ground-truth capture the re-fold must reproduce; it drives the
// SAME run_startup + step_tick + render_version seam the production re-fold capture
// does, the only difference being that the input here is the live scripted snapshot
// rather than one parsed from a recorded log. Hunt is SEEDLESS: no Rng is threaded.
@(private = "file")
hunt_live_capture :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> Frame_Capture {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	time := hunt_time(program.entrypoint.tick_hz, allocator)
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	for input in inputs {
		version = step_tick(program, version, input, time, allocator)
		draw := render_version(program, version, input, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}

// record_hunt_session records the scripted session through the production recorder
// against the golden hunt artifact's pinned identity and returns the finished log
// bytes — the byte-stable record both the live-vs-replay test re-folds and the
// regeneration test persists. The header pins the SEEDLESS golden identity derived
// from the real artifact bytes, so the log re-folds against the exact build it was
// recorded for (§09 §5).
@(private = "file")
record_hunt_session :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> string {
	identity := identity_from_program(program^, HUNT_ARTIFACT)
	writer := open_replay_writer(identity, allocator)
	defer delete_replay_writer(&writer)
	for input in inputs {
		record_tick(&writer, input, allocator)
	}
	return finish_replay(&writer, allocator)
}

// hunter_ai_case reads Hunter id=`idx`'s `ai` enum column at a committed version
// and returns its case name (the "Case" half of the stored "Hunt::Case" token) —
// the probe the AI-cycle assertion reads transitions through. An absent table or
// row, or a non-enum column, yields "" so the assertion fails closed.
@(private = "file")
hunter_ai_case :: proc(version: ^World_Version, idx: int) -> string {
	table := version_find_table(version, "Hunter")
	if table == nil || idx < 0 || idx >= len(table.rows) {
		return ""
	}
	token, ok := table.rows[idx].fields["ai"].(string)
	if !ok {
		return ""
	}
	return variant_from_token(token).case_name
}

@(test)
test_scripted_session_cycles_hunter_ai :: proc(t: ^testing.T) {
	// The scripted session cycles Hunter id=0 through ALL THREE AI states so the
	// digest folds every think arm and every hunter_color render arm (§10, §20):
	// Patrol -> Chase (on sight) -> Search (lost sight, timer armed) -> Patrol
	// (timer expired). The transition tick indices are asserted EXACTLY — they are
	// stable arithmetic over the Q32.32 kernel (no float, no RNG; input is the sole
	// nondeterminism source, Lore #7), so a shifted index is a determinism
	// regression, not a flaky timing. This is the proof the golden digest provably
	// folds all three states (and the contiguous per-tick spans between them give
	// the distinct, evolving per-tick frames the digest acceptance rests on).
	context.allocator = context.temp_allocator

	program, ok := load_hunt(t)
	if !ok {
		return
	}
	world := new_world(program, context.temp_allocator)
	version := run_startup(&program, initial_version(world, context.temp_allocator))
	time := hunt_time(program.entrypoint.tick_hz)
	inputs := hunt_session_inputs()

	// Hunter id=0 spawns in Patrol (the =Hunt::Patrol composite default applied at
	// setup) — the precondition the whole cycle starts from.
	testing.expect_value(t, hunter_ai_case(&version, 0), "Patrol")

	states := make([]string, len(inputs), context.temp_allocator)
	for input, i in inputs {
		version = step_tick(&program, version, input, time)
		states[i] = hunter_ai_case(&version, 0)
	}

	// Each transition lands at exactly its asserted tick, and the state is stable
	// across the whole span between transitions — so every arm folds a contiguous
	// run of distinct per-tick frames, not a single transient tick.
	testing.expect_value(t, states[HUNT_CHASE_TICK - 1], "Patrol")
	testing.expect_value(t, states[HUNT_CHASE_TICK], "Chase")
	testing.expect_value(t, states[HUNT_SEARCH_TICK - 1], "Chase")
	testing.expect_value(t, states[HUNT_SEARCH_TICK], "Search")
	testing.expect_value(t, states[HUNT_PATROL_TICK - 1], "Search")
	testing.expect_value(t, states[HUNT_PATROL_TICK], "Patrol")
	// The tail stays in the re-acquired Patrol state through the end of the session.
	testing.expect_value(t, states[len(states) - 1], "Patrol")
}

@(test)
test_hunt_live_run_and_refold_have_identical_digests :: proc(t: ^testing.T) {
	// A live hunt run and the production re-fold of its RECORDED log yield
	// bit-identical per-tick AND session frame digests (§07 §4, §20). The live
	// capture and the re-fold capture share only the artifact and the recorded
	// snapshots — the re-fold substitutes nothing but the input source (the parsed
	// log) — so equal per-tick digests prove every committed tick matched (including
	// every AI transition) and an equal session digest is the whole-run summary of
	// that match. The re-fold runs through the production replay_capture driver
	// (identity-gated, SEEDLESS), not a test-only tick loop, so the harness exercises
	// the real recorder -> reader -> driver path over hunt's multi-thing surface.
	context.allocator = context.temp_allocator

	live_program, ok := load_hunt(t)
	if !ok {
		return
	}
	inputs := hunt_session_inputs()
	live := hunt_live_capture(&live_program, inputs)

	// Record the scripted session, then read it back through the production parser —
	// the re-fold re-feeds these parsed snapshots, never the live run's state.
	log_bytes := record_hunt_session(&live_program, inputs)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}

	// Re-fold against a FRESH program load through the production capturing driver.
	refold_program, refold_ok := load_hunt(t)
	if !refold_ok {
		return
	}
	result := replay_capture(&refold_program, HUNT_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	if !testing.expect_value(t, len(result.capture.per_tick), len(live.per_tick)) {
		return
	}
	for frame, i in live.per_tick {
		testing.expect_value(t, result.capture.per_tick[i].tick, frame.tick)
		testing.expect_value(t, result.capture.per_tick[i].digest, frame.digest)
	}
	testing.expect_value(t, result.capture.session, live.session)
}

@(test)
test_committed_hunt_log_reproduces_expected_digest :: proc(t: ^testing.T) {
	// The COMMITTED hunt golden replay log, re-folded on the CURRENT build, produces
	// a session digest exactly equal to the COMMITTED expected digest fixture (§09
	// §5, §28). This is the cross-build two-machine proxy: input is the sole recorded
	// nondeterminism source (hunt is seedless — no RNG, no seed, Lore #7) and the
	// interpreter is the determinism ground truth, so a DIFFERENT build re-folding
	// this SAME committed log must reproduce this SAME digest — a passing run on a
	// second machine is a bit-identical reproduction. A divergence here is the
	// determinism target failing, not a stale fixture.
	context.allocator = context.temp_allocator

	program, ok := load_hunt(t)
	if !ok {
		return
	}

	log, parse_ok := read_replay(HUNT_GOLDEN_REPLAY_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}

	result := replay_capture(&program, HUNT_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	expected, digest_ok := parse_hunt_committed_digest(HUNT_GOLDEN_EXPECTED_DIGEST)
	if !testing.expect(t, digest_ok) {
		return
	}
	testing.expect_value(t, result.capture.session, expected)
}

// parse_hunt_committed_digest reads the committed expected-digest fixture — a
// decimal u64 with any trailing newline trimmed — into its u64 value. The fixture
// is a bare decimal so a human can read the committed digest at a glance and a
// regeneration writes it back the same way; ok is false on a malformed fixture so
// the test fails closed rather than comparing against a zero default.
@(private = "file")
parse_hunt_committed_digest :: proc(text: string) -> (digest: u64, ok: bool) {
	trimmed := strings.trim_space(text)
	return strconv.parse_u64(trimmed)
}

@(test)
test_regenerate_hunt_golden_fixtures :: proc(t: ^testing.T) {
	// Regeneration is armed only by FUNPACK_REGEN_GOLDEN — a normal `task test` run
	// SKIPS this, so the committed fixtures are never silently rewritten by an
	// ordinary test pass; only a deliberate regeneration touches them. When armed, it
	// records the scripted session through the production recorder, writes the
	// byte-stable log to testdata/hunt_golden.replay, re-folds it through the
	// production capturing driver, and writes the produced session digest (decimal
	// u64) to testdata/hunt_golden.digest — both relative to the runtime/ cwd
	// `task -d runtime test` runs from. Commit both regenerated files.
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) == "" {
		return
	}
	context.allocator = context.temp_allocator

	program, ok := load_hunt(t)
	if !ok {
		return
	}
	inputs := hunt_session_inputs()
	log_bytes := record_hunt_session(&program, inputs)

	log_path, log_join_err := filepath.join({"testdata", "hunt_golden.replay"})
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
	result := replay_capture(&program, HUNT_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	digest_buf: [20]byte
	digest_text := strconv.write_uint(digest_buf[:], result.capture.session, 10)
	digest_path, digest_join_err := filepath.join({"testdata", "hunt_golden.digest"})
	if !testing.expect(t, digest_join_err == nil) {
		return
	}
	testing.expect(t, os.write_entire_file_from_string(digest_path, digest_text) == nil)
}
