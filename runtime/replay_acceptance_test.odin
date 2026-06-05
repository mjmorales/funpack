// Two-machine bit-identity acceptance harness (spec §07 §4, §09 §5, §20, §28):
// the milestone's determinism-target carrier. It proves, end to end and against
// the REAL golden pong artifact, the three properties a deterministic-replay claim
// rests on:
//
//   - LIVE-VS-REPLAY BIT-IDENTITY: a live pong run captured per-tick (the digest
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
//     ground-truth: input is the sole nondeterminism source, so the committed log
//     plus the committed digest are the durable milestone regression fixtures);
//   - GATE REPRODUCTION RECIPE: a true cross-hardware/second-build run is
//     operator-gated, not CI-mechanizable — the operator runs the same golden
//     re-fold on a second machine or an independently rebuilt binary and confirms
//     the produced session digest equals the committed expected digest. The
//     GOLDEN-FIXTURE REGENERATION + OPERATOR GATE recipe below documents both the
//     regeneration command and the exact reproduction command.
//
// GOLDEN-FIXTURE REGENERATION (rebuild the committed log + expected digest):
//
//     FUNPACK_REGEN_GOLDEN=1 task -d runtime test
//
// That env var arms test_regenerate_golden_fixtures, which records the scripted
// session (golden_session_inputs) through the production recorder against the
// golden artifact's pinned identity, writes the byte-stable log to
// testdata/pong_golden.replay, re-folds it through replay_capture, and writes the
// produced session digest (decimal u64) to testdata/pong_golden.digest. Commit both
// regenerated files. Regenerate ONLY when a deliberate change to the artifact, the
// replay encoding, or the frame-digest encoding intentionally moves the digest — a
// digest that moves without such a change is a determinism regression, not a stale
// fixture.
//
// OPERATOR GATE — second-machine / second-build reproduction (verifies_by:gate):
// on a second machine, or against an independently rebuilt binary, run
//
//     task -d runtime test
//
// and confirm test_committed_golden_log_reproduces_expected_digest PASSES. That
// test re-folds the COMMITTED testdata/pong_golden.replay on the build under test
// and asserts its session digest equals the COMMITTED testdata/pong_golden.digest —
// so a passing run on the second machine is a bit-identical reproduction of the
// committed digest. The committed fixtures are embedded with #load, so the
// reproduction needs no funpack source and no cwd — only the runtime package and the
// committed testdata/.
package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

// GOLDEN_REPLAY_LOG is the committed golden pong replay log, embedded at compile
// time the same hermetic way GOLDEN_ARTIFACT is — so the cross-build re-fold test
// runs with no filesystem and no cwd, only the runtime package. It is the byte-
// stable log golden_session_inputs records through the production recorder; the
// regeneration test rewrites this file from the embedded artifact.
GOLDEN_REPLAY_LOG := #load("testdata/pong_golden.replay", string)

// GOLDEN_EXPECTED_DIGEST is the committed expected session digest of the golden
// log's re-fold, embedded as a decimal u64 text fixture. A build that re-folds
// GOLDEN_REPLAY_LOG must reproduce exactly this value; a divergence is the
// determinism target failing, not a stale fixture. Parsed by parse_committed_digest.
GOLDEN_EXPECTED_DIGEST := #load("testdata/pong_golden.digest", string)

// GOLDEN_SESSION_TICKS is the scripted session length: long enough that the ball
// crosses an edge and serves, so the recorded run folds the scoring + serve +
// signal-route paths, not a straight-line advance — the same non-trivial shape the
// replay re-fold test exercises.
@(private = "file")
GOLDEN_SESSION_TICKS :: 600

// GOLDEN_STEER is pong's Steer::Move axis action — ActionId 0, the sole Axis
// variant in the declaration walk. The scripted session drives the left paddle
// through it so the committed state evolves tick to tick and the per-tick digests
// are distinct.
@(private = "file")
GOLDEN_STEER :: ActionId(0)

// golden_session_inputs builds the scripted input session the golden fixtures are
// generated from and the live-vs-replay test drives: P1 holds Steer::Move at +1
// for the first half, then releases it — the left paddle moves then sits while the
// ball free-runs and serves. The SAME sequence drives the live capture and is
// recorded for the re-fold, so the two captures must agree; it is also the sole
// source the committed golden log is regenerated from, so the fixtures stay
// reproducible from this one definition.
@(private = "file")
golden_session_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, GOLDEN_SESSION_TICKS, allocator)
	for i in 0 ..< GOLDEN_SESSION_TICKS {
		if i < GOLDEN_SESSION_TICKS / 2 {
			inputs[i] = with_value(empty(), .P1, GOLDEN_STEER, to_fixed(1))
		} else {
			inputs[i] = empty()
		}
	}
	return inputs
}

// live_capture drives a golden pong session LIVE — restarting from setup and
// stepping the tick loop once per scripted input — capturing each committed tick's
// frame digest over the world state and its §20 draw-list, then folding the session
// digest. It is the ground-truth capture the re-fold must reproduce; it drives the
// SAME run_startup + step_tick + render_version seam the production re-fold capture
// does, the only difference being that the input here is the live scripted snapshot
// rather than one parsed from a recorded log.
@(private = "file")
live_capture :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> Frame_Capture {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	time := golden_time(program.entrypoint.tick_hz, allocator)
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	for input in inputs {
		version = step_tick(program, version, input, time, allocator)
		draw := render_version(program, version, input, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}

// golden_time builds the Time resource the live capture steps at — the one `dt`
// field at the artifact's fixed tick rate (1/tick_hz in Q32.32 through the kernel,
// no float). The replay driver derives Time the same way, so the live run and the
// re-fold step at identical dt: any digest divergence would be the input source, not
// the clock.
@(private = "file")
golden_time :: proc(tick_hz: int, allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(i64(tick_hz)))
	return Record_Value{type_name = "Time", fields = fields}
}

// record_golden_session records the scripted session through the production
// recorder against the golden artifact's pinned identity and returns the finished
// log bytes — the byte-stable record both the live-vs-replay test re-folds and the
// regeneration test persists. The header pins the golden identity derived from the
// real artifact bytes, so the log re-folds against the exact build it was recorded
// for (§09 §5).
@(private = "file")
record_golden_session :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> string {
	identity := identity_from_program(program^, GOLDEN_ARTIFACT)
	writer := open_replay_writer(identity, allocator)
	defer delete_replay_writer(&writer)
	for input in inputs {
		record_tick(&writer, input, allocator)
	}
	return finish_replay(&writer, allocator)
}

@(test)
test_live_run_and_refold_have_identical_digests :: proc(t: ^testing.T) {
	// A live pong run and the production re-fold of its RECORDED log yield
	// bit-identical per-tick AND session frame digests (§07 §4, §20). The live
	// capture and the re-fold capture share only the artifact and the recorded
	// snapshots — the re-fold substitutes nothing but the input source (the parsed
	// log) — so equal per-tick digests prove every committed tick matched and an
	// equal session digest is the whole-run summary of that match. The re-fold runs
	// through the production replay_capture driver (identity-gated), not a test-only
	// tick loop, so the harness exercises the real recorder → reader → driver path.
	context.allocator = context.temp_allocator

	live_program, ok := load_golden(t)
	if !ok {
		return
	}
	inputs := golden_session_inputs()
	live := live_capture(&live_program, inputs)

	// Record the scripted session, then read it back through the production parser —
	// the re-fold re-feeds these parsed snapshots, never the live run's state.
	log_bytes := record_golden_session(&live_program, inputs)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}

	// Re-fold against a FRESH program load through the production capturing driver.
	refold_program, refold_ok := load_golden(t)
	if !refold_ok {
		return
	}
	result := replay_capture(&refold_program, GOLDEN_ARTIFACT, log)
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
test_committed_golden_log_reproduces_expected_digest :: proc(t: ^testing.T) {
	// The COMMITTED golden replay log, re-folded on the CURRENT build, produces a
	// session digest exactly equal to the COMMITTED expected digest fixture (§09 §5,
	// §28). This is the cross-build two-machine proxy: input is the sole recorded
	// nondeterminism source and the interpreter is the determinism ground truth, so a
	// DIFFERENT build re-folding this SAME committed log must reproduce this SAME
	// digest — a passing run on a second machine is a bit-identical reproduction. A
	// divergence here is the determinism target failing, not a stale fixture.
	context.allocator = context.temp_allocator

	program, ok := load_golden(t)
	if !ok {
		return
	}

	log, parse_ok := read_replay(GOLDEN_REPLAY_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}

	result := replay_capture(&program, GOLDEN_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	expected, digest_ok := parse_committed_digest(GOLDEN_EXPECTED_DIGEST)
	if !testing.expect(t, digest_ok) {
		return
	}
	testing.expect_value(t, result.capture.session, expected)
}

// parse_committed_digest reads the committed expected-digest fixture — a decimal
// u64 with any trailing newline trimmed — into its u64 value. The fixture is a bare
// decimal so a human can read the committed digest at a glance and a regeneration
// writes it back the same way; ok is false on a malformed fixture so the test fails
// closed rather than comparing against a zero default.
@(private = "file")
parse_committed_digest :: proc(text: string) -> (digest: u64, ok: bool) {
	trimmed := strings.trim_space(text)
	return strconv.parse_u64(trimmed)
}

@(test)
test_regenerate_golden_fixtures :: proc(t: ^testing.T) {
	// Regeneration is armed only by FUNPACK_REGEN_GOLDEN — a normal `task test` run
	// SKIPS this, so the committed fixtures are never silently rewritten by an
	// ordinary test pass; only a deliberate regeneration touches them. When armed, it
	// records the scripted session through the production recorder, writes the
	// byte-stable log to testdata/pong_golden.replay, re-folds it through the
	// production capturing driver, and writes the produced session digest (decimal
	// u64) to testdata/pong_golden.digest — both relative to the runtime/ cwd
	// `task -d runtime test` runs from. Commit both regenerated files.
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) == "" {
		return
	}
	context.allocator = context.temp_allocator

	program, ok := load_golden(t)
	if !ok {
		return
	}
	inputs := golden_session_inputs()
	log_bytes := record_golden_session(&program, inputs)

	log_path, log_join_err := filepath.join({"testdata", "pong_golden.replay"})
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
	result := replay_capture(&program, GOLDEN_ARTIFACT, log)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	digest_buf: [20]byte
	digest_text := strconv.write_uint(digest_buf[:], result.capture.session, 10)
	digest_path, digest_join_err := filepath.join({"testdata", "pong_golden.digest"})
	if !testing.expect(t, digest_join_err == nil) {
		return
	}
	testing.expect(t, os.write_entire_file_from_string(digest_path, digest_text) == nil)
}
