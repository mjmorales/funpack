// Snake SEEDED two-machine bit-identity acceptance harness (spec §01 §50/§60,
// §04 §1, §07 §4, §09 §5, §20, §25 §60, §28) — the determinism floor for a game
// whose nondeterminism inputs are Input AND the recorded tick-0 RNG seed. It is
// the snake twin of replay_acceptance_test.odin (pong), proving the SAME three
// properties under a FIXED SEED, where the seed rides the determinism record
// exactly as Input does (recorded, never ambient):
//
//   - LIVE-VS-REPLAY BIT-IDENTITY (seeded): a live snake run started under the
//     fixed seed, captured per-tick, and the production re-fold of its RECORDED
//     log — re-fed the SAME seed through the identity-gated replay_capture driver
//     (run_seed = seeded_run(SEED)) — produce bit-identical per-tick AND session
//     frame digests. The seeded setup draws the first food cell from the seed and
//     each tick threads the persistent Rng, so reproducing the seed reproduces
//     every RNG-driven spawn/despawn/grow (§04 §1, §25 §60);
//   - CROSS-BUILD GOLDEN RE-FOLD (seeded): the committed golden snake log
//     (testdata/snake_golden.replay), re-folded on the CURRENT build under the seed
//     pinned in its v2 header, reproduces the committed expected session digest
//     (testdata/snake_golden.digest) bit-identically — the CI-runnable proxy for a
//     second machine, since a different build re-folding the same committed log+seed
//     must reproduce the same committed digest (§09 §5);
//   - SEED IS RECORDED, NOT AMBIENT: the golden log header carries the tick-0 seed
//     (Replay_Identity.has_seed/seed), and a re-fold under a DIFFERENT seed is
//     REFUSED by the identity gate (a seed change yields a different recorded
//     identity, §01 §50, §25 §60) — proved by test_snake_golden_seed_is_recorded.
//
// The scripted session (snake_golden_inputs) steers the seed-42 snake from its
// (10,10) start onto the seed-spawned food at (16,14): six ticks Right, then
// Move::Down held, so the head lands on the food, detect_eat fires Eaten,
// despawn_eaten removes the eaten Food, grow flags growth, and replenish draws a
// REPLACEMENT food from the threaded Rng — the digest folds the full
// spawn/despawn/grow/RNG path, not a straight-line advance. The run continues to an
// off-grid death so the §state machine folds too.
//
// GOLDEN-FIXTURE REGENERATION (rebuild the committed log + expected digest):
//
//     FUNPACK_REGEN_GOLDEN=1 task -d runtime test
//
// That env var arms test_regenerate_snake_golden_fixtures, which records the
// scripted session through the production recorder against the golden snake
// artifact's SEEDED identity (the seed pinned in the v2 header), writes the
// byte-stable log to testdata/snake_golden.replay, re-folds it through
// replay_capture under the SAME seed, and writes the produced session digest
// (decimal u64) to testdata/snake_golden.digest. Commit both regenerated files.
// Regenerate ONLY when a deliberate change to the artifact, the replay encoding, the
// frame-digest encoding, or the seed intentionally moves the digest — a digest that
// moves without such a change is a determinism regression, not a stale fixture.
//
// OPERATOR GATE — second-machine / second-build reproduction (verifies_by:gate):
// on a second machine, or against an independently rebuilt binary, run
//
//     task -d runtime test
//
// and confirm test_snake_committed_golden_log_reproduces_expected_digest PASSES.
// That test re-folds the COMMITTED testdata/snake_golden.replay on the build under
// test, UNDER THE PINNED SEED (seeded_run(SNAKE_GOLDEN_SEED)), and asserts its
// session digest equals the COMMITTED testdata/snake_golden.digest — so a passing
// run on the second machine is a bit-identical reproduction of the committed digest
// for the committed seed. The committed fixtures are embedded with #load, so the
// reproduction needs no funpack source and no cwd — only the runtime package and the
// committed testdata/.
package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

// GOLDEN_SNAKE_ARTIFACT is the committed golden snake artifact, embedded at
// compile time the hermetic way GOLDEN_ARTIFACT (pong) is, so every snake
// acceptance test runs with no filesystem and no cwd — only the runtime package.
// It is the real artifact the sibling funpack epic emits from the snake .fun
// source; the seeded setup body it carries draws the first food from the run seed.
GOLDEN_SNAKE_ARTIFACT := #load("testdata/snake.artifact", string)

// SNAKE_GOLDEN_LOG is the committed golden snake replay log, embedded so the
// cross-build re-fold test needs no filesystem. Its v2 header pins the build
// fingerprint AND the tick-0 seed; the regeneration test rewrites it.
SNAKE_GOLDEN_LOG := #load("testdata/snake_golden.replay", string)

// SNAKE_GOLDEN_DIGEST is the committed expected session digest of the snake
// golden log's seeded re-fold, embedded as a decimal u64 text fixture. A build
// re-folding SNAKE_GOLDEN_LOG under the pinned seed must reproduce exactly this
// value; a divergence is the seeded determinism target failing, not a stale
// fixture.
SNAKE_GOLDEN_DIGEST := #load("testdata/snake_golden.digest", string)

// SNAKE_GOLDEN_SEED is the fixed tick-0 RNG seed the golden snake run is recorded
// and re-folded under. It pins the seed-spawned food layout (first food at (16,14),
// the replacement at (3,3)), so the scripted session reaches the food
// deterministically. The seed is RECORDED in the log header (§25 §60) — it rides
// the determinism record exactly as Input does — so a re-fold re-feeds this exact
// value and a different seed is refused.
@(private = "file")
SNAKE_GOLDEN_SEED :: i64(42)

// SNAKE_GOLDEN_TICKS is the scripted session length: long enough that the snake
// eats the seed-spawned food (firing the despawn/grow/replenish-RNG path) and then
// runs off the grid (firing the death state machine), so the recorded run folds the
// full snake surface, not a straight-line advance.
@(private = "file")
SNAKE_GOLDEN_TICKS :: 16

// MOVE_DOWN is snake's Move::Down Button action — ActionId 1 in the deterministic
// enum walk (the Button-kinded `Move` enum's variants mint Up=0, Down=1, Left=2,
// Right=3 in declaration order, bindings_resolve §23 §1). The scripted session
// presses it to steer the snake down onto the seed-spawned food after running
// right; the snake starts facing Right, so no input is needed for the rightward leg.
@(private = "file")
MOVE_DOWN :: ActionId(1)

// SNAKE_TURN_TICK is the tick the scripted session presses Move::Down — after six
// rightward ticks carry the head from x=10 to x=16 (the food's column under
// SNAKE_GOLDEN_SEED), the turn steers it down toward the food's row y=14.
@(private = "file")
SNAKE_TURN_TICK :: 6

// snake_golden_inputs builds the scripted seeded session the golden fixtures are
// generated from and the live-vs-replay test drives: the snake free-runs Right for
// the first SNAKE_TURN_TICK ticks (its default heading), then Move::Down is pressed
// to turn it down onto the seed-spawned food at (16,14). The press is an EDGE (one
// tick) since dir_from_input reads `pressed`; the head keeps its new heading after.
// The SAME sequence drives the live capture and is recorded for the re-fold, so the
// two captures must agree, and it is the sole source the committed golden log is
// regenerated from, so the fixtures stay reproducible from this one definition.
@(private = "file")
snake_golden_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, SNAKE_GOLDEN_TICKS, allocator)
	for i in 0 ..< SNAKE_GOLDEN_TICKS {
		if i == SNAKE_TURN_TICK {
			inputs[i] = with_pressed(empty(), .P1, MOVE_DOWN)
		} else {
			inputs[i] = empty()
		}
	}
	return inputs
}

// load_snake_golden parses the embedded snake artifact into a Program against the
// test's temp allocator. A parse failure fails the test and returns ok=false so the
// caller bails — the artifact is committed, so a failure here is a corrupt or
// schema-drifted fixture, not a transient condition.
@(private = "file")
load_snake_golden :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(GOLDEN_SNAKE_ARTIFACT, context.temp_allocator)
	if !testing.expect_value(t, err, Artifact_Error.None) {
		return {}, false
	}
	return loaded, true
}

// snake_live_capture drives the golden snake session LIVE under the fixed seed —
// restarting from the SEEDED setup (run_startup_seeded, which draws the first food
// from the seed) and stepping the tick loop once per scripted input, threading the
// persistent Rng so every RNG-driven spawn folds — capturing each committed tick's
// frame digest over the world state and its §20 draw-list, then folding the session
// digest. It is the ground-truth capture the re-fold must reproduce: it drives the
// SAME run_startup_seeded + step_tick(&rng) + render_version seam refold_capture
// does, the only difference being the input is the live scripted snapshot rather
// than one parsed from the recorded log.
@(private = "file")
snake_live_capture :: proc(
	program: ^Program,
	inputs: []Input,
	seed: i64,
	allocator := context.allocator,
) -> Frame_Capture {
	world := new_world(program^, allocator)
	version, rng := run_startup_seeded(program, initial_version(world, allocator), rand_seed(seed), allocator)
	current := rng
	time := snake_golden_time(program.entrypoint.tick_hz, allocator)
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	for input in inputs {
		version = step_tick(program, version, input, time, allocator, &current)
		draw := render_version(program, version, input, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}

// snake_golden_time builds the Time resource the seeded live capture steps at — the
// one `dt` field at the artifact's fixed tick rate (1/tick_hz in Q32.32 through the
// kernel, no float). The replay driver derives Time the same way, so the live run
// and the re-fold step at identical dt: any digest divergence would be the input
// source or the seed, not the clock.
@(private = "file")
snake_golden_time :: proc(tick_hz: int, allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(i64(tick_hz)))
	return Record_Value{type_name = "Time", fields = fields}
}

// record_snake_golden_session records the scripted session through the production
// recorder against the golden snake artifact's SEEDED identity and returns the
// finished log bytes — the byte-stable record both the live-vs-replay test re-folds
// and the regeneration test persists. The header pins the seeded identity
// (identity_from_program_seeded) so the recorded SEED rides the log, and a re-fold
// must be started under the SAME seed or the identity gate refuses it (§09 §5, §25
// §60).
@(private = "file")
record_snake_golden_session :: proc(
	program: ^Program,
	inputs: []Input,
	seed: i64,
	allocator := context.allocator,
) -> string {
	identity := identity_from_program_seeded(program^, GOLDEN_SNAKE_ARTIFACT, seed)
	writer := open_replay_writer(identity, allocator)
	defer delete_replay_writer(&writer)
	for input in inputs {
		record_tick(&writer, input, allocator)
	}
	return finish_replay(&writer, allocator)
}

@(test)
test_snake_live_run_and_refold_have_identical_digests :: proc(t: ^testing.T) {
	// A live SEEDED snake run and the production re-fold of its RECORDED log yield
	// bit-identical per-tick AND session frame digests (§07 §4, §20, §25 §60). The
	// live capture and the re-fold capture share only the artifact, the recorded
	// snapshots, AND the seed — the re-fold substitutes nothing but the input source
	// (the parsed log) while re-feeding the SAME seed (run_seed = seeded_run(SEED)) —
	// so equal per-tick digests prove every committed tick (including the seed-driven
	// food spawn/despawn) matched, and an equal session digest is the whole-run
	// summary. The re-fold runs through the production identity-gated replay_capture
	// driver, so the harness exercises the real recorder → reader → seeded driver path.
	context.allocator = context.temp_allocator

	live_program, ok := load_snake_golden(t)
	if !ok {
		return
	}
	inputs := snake_golden_inputs()
	live := snake_live_capture(&live_program, inputs, SNAKE_GOLDEN_SEED)

	// Record the scripted session, then read it back through the production parser —
	// the re-fold re-feeds these parsed snapshots and the recorded seed, never the
	// live run's state.
	log_bytes := record_snake_golden_session(&live_program, inputs, SNAKE_GOLDEN_SEED)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}

	// Re-fold against a FRESH program load through the production capturing driver,
	// started under the SAME seed the log pins.
	refold_program, refold_ok := load_snake_golden(t)
	if !refold_ok {
		return
	}
	result := replay_capture(
		&refold_program,
		GOLDEN_SNAKE_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SNAKE_GOLDEN_SEED),
	)
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
test_snake_committed_golden_log_reproduces_expected_digest :: proc(t: ^testing.T) {
	// The COMMITTED snake golden replay log, re-folded on the CURRENT build UNDER THE
	// PINNED SEED, produces a session digest exactly equal to the COMMITTED expected
	// digest fixture (§09 §5, §25 §60, §28). This is the seeded cross-build two-machine
	// proxy: Input + the recorded tick-0 seed are the determinism inputs and the
	// interpreter is the ground truth, so a DIFFERENT build re-folding this SAME
	// committed log under this SAME seed must reproduce this SAME digest — a passing
	// run on a second machine is a bit-identical reproduction. A divergence here is the
	// seeded determinism target failing, not a stale fixture.
	context.allocator = context.temp_allocator

	program, ok := load_snake_golden(t)
	if !ok {
		return
	}

	log, parse_ok := read_replay(SNAKE_GOLDEN_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}

	result := replay_capture(
		&program,
		GOLDEN_SNAKE_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SNAKE_GOLDEN_SEED),
	)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	expected, digest_ok := parse_snake_committed_digest(SNAKE_GOLDEN_DIGEST)
	if !testing.expect(t, digest_ok) {
		return
	}
	testing.expect_value(t, result.capture.session, expected)
}

@(test)
test_snake_golden_seed_is_recorded_not_ambient :: proc(t: ^testing.T) {
	// The golden snake log header CARRIES the tick-0 seed (it is recorded, not
	// ambient, §25 §60), and re-folding it under a DIFFERENT seed is REFUSED by the
	// identity gate — a seed change yields a different recorded identity (§01 §50). The
	// committed log re-folds cleanly under the pinned seed (refusal None) but is
	// refused (Identity_Mismatch) under any other seed, so the seed is part of the
	// recorded determinism record exactly as the build fingerprint is. This is the
	// agent-verified property "the recorded log header carries the tick-0 seed and a
	// seed change yields a different recorded identity".
	context.allocator = context.temp_allocator

	program, ok := load_snake_golden(t)
	if !ok {
		return
	}
	log, parse_ok := read_replay(SNAKE_GOLDEN_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}

	// The recorded log's identity carries the seed (has_seed true, the pinned value).
	if !testing.expect(t, log.identity.has_seed) {
		return
	}
	testing.expect_value(t, log.identity.seed, SNAKE_GOLDEN_SEED)

	// Re-fold under the PINNED seed: accepted (refusal None).
	matched := replay_capture(
		&program,
		GOLDEN_SNAKE_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SNAKE_GOLDEN_SEED),
	)
	testing.expect_value(t, matched.refusal, Replay_Refusal.None)

	// Re-fold under a DIFFERENT seed: refused — the seed moves the recorded identity.
	mismatched := replay_capture(
		&program,
		GOLDEN_SNAKE_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SNAKE_GOLDEN_SEED + 1),
	)
	testing.expect_value(t, mismatched.refusal, Replay_Refusal.Identity_Mismatch)
}

// parse_snake_committed_digest reads the committed expected-digest fixture — a
// decimal u64 with any trailing newline trimmed — into its u64 value. The fixture
// is a bare decimal so a human can read the committed digest at a glance and a
// regeneration writes it back the same way; ok is false on a malformed fixture so
// the test fails closed rather than comparing against a zero default.
@(private = "file")
parse_snake_committed_digest :: proc(text: string) -> (digest: u64, ok: bool) {
	trimmed := strings.trim_space(text)
	return strconv.parse_u64(trimmed)
}

@(test)
test_regenerate_snake_golden_fixtures :: proc(t: ^testing.T) {
	// Regeneration is armed only by FUNPACK_REGEN_GOLDEN — a normal `task test` run
	// SKIPS this, so the committed snake fixtures are never silently rewritten by an
	// ordinary test pass; only a deliberate regeneration touches them. When armed, it
	// records the scripted seeded session through the production recorder (the seed
	// pinned in the v2 header), writes the byte-stable log to
	// testdata/snake_golden.replay, re-folds it through the production capturing driver
	// under the SAME seed, and writes the produced session digest (decimal u64) to
	// testdata/snake_golden.digest — both relative to the runtime/ cwd
	// `task -d runtime test` runs from. Commit both regenerated files.
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) == "" {
		return
	}
	context.allocator = context.temp_allocator

	program, ok := load_snake_golden(t)
	if !ok {
		return
	}
	inputs := snake_golden_inputs()
	log_bytes := record_snake_golden_session(&program, inputs, SNAKE_GOLDEN_SEED)

	log_path, log_join_err := filepath.join({"testdata", "snake_golden.replay"})
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
	result := replay_capture(
		&program,
		GOLDEN_SNAKE_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SNAKE_GOLDEN_SEED),
	)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	digest_buf: [20]byte
	digest_text := strconv.write_uint(digest_buf[:], result.capture.session, 10)
	digest_path, digest_join_err := filepath.join({"testdata", "snake_golden.digest"})
	if !testing.expect(t, digest_join_err == nil) {
		return
	}
	testing.expect(t, os.write_entire_file_from_string(digest_path, digest_text) == nil)
}
