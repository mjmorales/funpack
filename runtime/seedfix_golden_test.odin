// Seedfix golden: the determinism + anti-black-screen acceptance for a uses_rng
// game whose SETUP IS SEEDLESS but whose PER-TICK behavior draws from the engine Rng
// (spec §25 §60, §04 §1, §07 §4, §09 §5, §20, §28). This is the deepseed shape the
// runtime-seed contract closes: the setup binds no Rng (program_is_seeded is false),
// so a gate keyed on setup-seeding would classify the run seedless and thread it no
// root Rng — its drawing behaviors would never fold and the window would render
// black. The engine instead gates the recorded root seed on program_uses_rng (any
// draw, setup or per-tick), resolves it (here the fixed engine default, since the
// game bakes no config seed and no --seed is passed), records it in the replay
// header, and threads it per tick. This golden proves the run folds, draws
// deterministically, records its seed, and re-folds bit-identically.
//
// The four pinned properties:
//
//   - SHAPE: the golden artifact is genuinely the seedless-setup, per-tick-RNG case
//     (program_is_seeded false, program_uses_rng true), and a bare run of it resolves
//     the fixed engine default seed (resolve_root_seed with no override/config seed).
//   - NON-EMPTY RE-FOLD (the anti-black-screen proof): the committed golden log,
//     re-folded under the recorded seed, commits a world with one drawn Mote per tick
//     plus the Spawner — a NON-EMPTY world, the exact thing the unseeded black screen
//     lacked.
//   - CROSS-BUILD DETERMINISM: the committed golden log re-folds on the current build
//     to the committed expected session digest bit-identically — the two-machine proxy.
//   - SEED IS RECORDED, NOT AMBIENT: the log header carries the root seed
//     (Replay_Identity.has_seed/seed), and a re-fold under a different seed is refused
//     by the identity gate.
//
// The session binds no input (the game has no bindings; it advances purely from the
// threaded Rng), so the scripted inputs are empty — every tick's nondeterminism is
// the root seed alone.
//
// GOLDEN-FIXTURE REGENERATION (rebuild the committed log + expected digest):
//
//     FUNPACK_REGEN_GOLDEN=1 task -d runtime test
//
// That arms test_regenerate_seedfix_golden_fixtures, which records the scripted
// session through the production recorder against the artifact's uses_rng identity
// (the resolved root seed pinned in the v2 header), writes the byte-stable log to
// testdata/seedfix_golden.replay, re-folds it through replay_capture under the SAME
// seed, and writes the session digest (decimal u64) to testdata/seedfix_golden.digest.
// Commit both. Regenerate ONLY when a deliberate change to the artifact, the replay
// encoding, the frame-digest encoding, or the seed intentionally moves the digest — a
// digest that moves without such a change is a determinism regression, not a stale
// fixture. The artifact itself is built from examples/seedfix (funpack build).
package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

// SEEDFIX_GOLDEN_ARTIFACT is the committed golden artifact, embedded so every
// acceptance test runs with no filesystem and no cwd. It is the real artifact funpack
// build emits from examples/seedfix: a seedless `setup() -> [Spawn]` and a per-tick
// `seed_draw on Spawner` that binds Rng and spawns a drawn Mote each tick.
SEEDFIX_GOLDEN_ARTIFACT := #load("testdata/seedfix.artifact", string)

// SEEDFIX_GOLDEN_LOG is the committed golden replay log, embedded for the cross-build
// re-fold. Its v2 header pins the build fingerprint AND the root seed; the
// regeneration test rewrites it.
SEEDFIX_GOLDEN_LOG := #load("testdata/seedfix_golden.replay", string)

// SEEDFIX_GOLDEN_DIGEST is the committed expected session digest of the golden log's
// re-fold, a decimal u64 text fixture. A build re-folding the log under the pinned
// seed must reproduce exactly this value; a divergence is the determinism target
// failing, not a stale fixture.
SEEDFIX_GOLDEN_DIGEST := #load("testdata/seedfix_golden.digest", string)

// SEEDFIX_GOLDEN_SEED is the root seed the golden run is recorded and re-folded under.
// It is the fixed engine default (RUNTIME_DEFAULT_SEED) — the value resolve_root_seed
// returns for this artifact, which bakes no config seed and is run with no --seed — so
// the golden mirrors exactly what a bare `funpack run examples/seedfix` records.
@(private = "file")
SEEDFIX_GOLDEN_SEED :: RUNTIME_DEFAULT_SEED

// SEEDFIX_GOLDEN_TICKS is the scripted session length: enough ticks that the per-tick
// draw spawns a visible population (one Mote per tick) for the non-empty-world and
// digest assertions to bite.
@(private = "file")
SEEDFIX_GOLDEN_TICKS :: 8

// seedfix_golden_inputs builds the scripted session: SEEDFIX_GOLDEN_TICKS empty
// inputs. The game binds no input, so every tick's only nondeterminism is the threaded
// Rng — the cleanest isolation of the seed contract. This one definition drives the
// live capture, the recorded log, and the regeneration, so the fixtures stay
// reproducible from it.
@(private = "file")
seedfix_golden_inputs :: proc(allocator := context.allocator) -> []Input {
	inputs := make([]Input, SEEDFIX_GOLDEN_TICKS, allocator)
	for i in 0 ..< SEEDFIX_GOLDEN_TICKS {
		inputs[i] = empty()
	}
	return inputs
}

// load_seedfix_golden parses the embedded artifact into a Program. A parse failure
// fails the test — the artifact is committed, so a failure here is a corrupt or
// schema-drifted fixture, not a transient condition.
@(private = "file")
load_seedfix_golden :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(SEEDFIX_GOLDEN_ARTIFACT, context.temp_allocator)
	if !testing.expect_value(t, err, Artifact_Error.None) {
		return {}, false
	}
	return loaded, true
}

// seedfix_live_capture drives the golden session LIVE through the production live seam
// for a uses_rng game: run_startup_rooted restarts from the root seed (here applying
// the seedless setup batch and entering tick 0 on the bare seed Rng, since setup binds
// no Rng), then step_tick(&rng) threads the persistent Rng so every per-tick draw
// folds, capturing each committed tick's frame digest. It is the ground truth the
// re-fold must reproduce.
@(private = "file")
seedfix_live_capture :: proc(
	program: ^Program,
	inputs: []Input,
	seed: i64,
	allocator := context.allocator,
) -> Frame_Capture {
	world := new_world(program^, allocator)
	version, rng := run_startup_rooted(program, initial_version(world, allocator), seed, allocator)
	current := rng
	time := time_resource(program.entrypoint.tick_hz, allocator)
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	for input in inputs {
		version = step_tick(program, version, input, time, allocator, &current)
		draw := render_version(program, version, input, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}

// record_seedfix_golden_session records the scripted session through the production
// recorder, returning the finished log bytes. The header identity is chosen by the
// SAME gate the live driver uses — program_uses_rng picks the seeded identity, so the
// root SEED rides the log for a drawing program and a re-fold must start under the SAME
// seed. Mirroring the live gate here (rather than hardcoding the seeded identity) makes
// this golden a regression guard for the gate decision itself: a gate reverted to
// program_is_seeded would record has_seed=false for this seedless-setup program,
// flipping the recorded header and failing the seed-recorded and non-empty re-fold
// tests.
@(private = "file")
record_seedfix_golden_session :: proc(
	program: ^Program,
	inputs: []Input,
	seed: i64,
	allocator := context.allocator,
) -> string {
	identity :=
		program_uses_rng(program) ? identity_from_program_seeded(program^, SEEDFIX_GOLDEN_ARTIFACT, seed) : identity_from_program(program^, SEEDFIX_GOLDEN_ARTIFACT)
	writer := open_replay_writer(identity, allocator)
	defer delete_replay_writer(&writer)
	for input in inputs {
		record_tick(&writer, input, allocator)
	}
	return finish_replay(&writer, allocator)
}

// parse_committed_digest reads a committed expected-digest fixture — a decimal u64
// with trailing whitespace trimmed — into its u64 value. ok is false on a malformed
// fixture so the test fails closed rather than comparing against a zero default.
@(private = "file")
parse_committed_digest :: proc(text: string) -> (digest: u64, ok: bool) {
	return strconv.parse_u64(strings.trim_space(text))
}

@(test)
test_seedfix_is_seedless_setup_but_uses_rng :: proc(t: ^testing.T) {
	// The golden artifact IS the seedless-setup, per-tick-RNG shape: program_is_seeded
	// is false (setup binds no Rng) but program_uses_rng is true (the seed_draw behavior
	// binds Rng). And a bare run of it resolves the FIXED ENGINE DEFAULT seed, since the
	// artifact bakes no config seed and no --seed override is given — so the recorded
	// golden seed is the same value an unattended `funpack run` would record.
	context.allocator = context.temp_allocator
	program, ok := load_seedfix_golden(t)
	if !ok {
		return
	}
	testing.expect(t, !program_is_seeded(&program))
	testing.expect(t, program_uses_rng(&program))
	testing.expect_value(t, resolve_root_seed(nil, program.entrypoint), SEEDFIX_GOLDEN_SEED)
}

@(test)
test_seedfix_golden_refold_renders_nonempty_world :: proc(t: ^testing.T) {
	// THE ANTI-BLACK-SCREEN PROOF: the committed golden log, re-folded under the
	// recorded root seed, commits a NON-EMPTY world — one drawn Mote per tick plus the
	// Spawner. An unseeded run of this shape would fold no behaviors and commit an empty
	// world (the black screen); a non-empty re-fold is the direct evidence the per-tick
	// draws folded. Every drawn cell lands in the behavior's [0, 10) range, confirming
	// the Motes carry real threaded-Rng draws, not field defaults.
	context.allocator = context.temp_allocator
	program, ok := load_seedfix_golden(t)
	if !ok {
		return
	}
	log, parse_ok := read_replay(SEEDFIX_GOLDEN_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}

	result := replay(
		&program,
		SEEDFIX_GOLDEN_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SEEDFIX_GOLDEN_SEED),
	)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	testing.expect_value(t, view_count(view_of_type(&result.world, "Spawner")), 1)
	motes := view_of_type(&result.world, "Mote")
	testing.expect_value(t, view_count(motes), SEEDFIX_GOLDEN_TICKS)

	// Pin the EXACT seed-driven sequence, not just the count: Mote i (Id-ascending, so
	// spawn order) carries the i-th range(0, 10) draw of rand_seed(SEEDFIX_GOLDEN_SEED),
	// hand-threaded through the kernel. This is the load-bearing guard — an unthreaded or
	// degenerate Rng (the black-screen path, where step_tick gets no Rng) still spawns
	// SEEDFIX_GOLDEN_TICKS Motes, but with cells from a zero-state generator, so only
	// pinning the drawn VALUES catches a per-tick threading regression. The same kernel
	// thread the runtime folds is reproduced by hand here, so a divergence is the
	// threading, never a stale expectation.
	hand := rand_seed(SEEDFIX_GOLDEN_SEED)
	for i in 0 ..< view_count(motes) {
		expected_cell, next := rand_range(hand, 0, 10)
		hand = next
		row, _ := view_at(motes, i)
		cell, present := row_field(row, "cell")
		testing.expect(t, present)
		testing.expect_value(t, cell.(i64), expected_cell)
	}
}

@(test)
test_committed_seedfix_log_reproduces_expected_digest :: proc(t: ^testing.T) {
	// The COMMITTED golden log, re-folded on the CURRENT build under the pinned seed,
	// produces a session digest exactly equal to the COMMITTED expected digest — the
	// cross-build two-machine determinism proxy. A divergence is the determinism target
	// failing, not a stale fixture.
	context.allocator = context.temp_allocator
	program, ok := load_seedfix_golden(t)
	if !ok {
		return
	}
	log, parse_ok := read_replay(SEEDFIX_GOLDEN_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}
	result := replay_capture(
		&program,
		SEEDFIX_GOLDEN_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SEEDFIX_GOLDEN_SEED),
	)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}
	expected, digest_ok := parse_committed_digest(SEEDFIX_GOLDEN_DIGEST)
	if !testing.expect(t, digest_ok) {
		return
	}
	testing.expect_value(t, result.capture.session, expected)
}

@(test)
test_seedfix_golden_seed_is_recorded_not_ambient :: proc(t: ^testing.T) {
	// The golden log header CARRIES the root seed (recorded, not ambient): has_seed is
	// true with the pinned value, the committed log re-folds cleanly under that seed, and
	// a re-fold under any other seed is REFUSED by the identity gate — a seed change
	// yields a different recorded identity. This proves the root seed is part of the
	// determinism record exactly as the build fingerprint is, for a game whose setup
	// never consumed a seed.
	context.allocator = context.temp_allocator
	program, ok := load_seedfix_golden(t)
	if !ok {
		return
	}
	log, parse_ok := read_replay(SEEDFIX_GOLDEN_LOG)
	if !testing.expect(t, parse_ok) {
		return
	}
	if !testing.expect(t, log.identity.has_seed) {
		return
	}
	testing.expect_value(t, log.identity.seed, SEEDFIX_GOLDEN_SEED)

	matched := replay_capture(
		&program,
		SEEDFIX_GOLDEN_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SEEDFIX_GOLDEN_SEED),
	)
	testing.expect_value(t, matched.refusal, Replay_Refusal.None)

	mismatched := replay_capture(
		&program,
		SEEDFIX_GOLDEN_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SEEDFIX_GOLDEN_SEED + 1),
	)
	testing.expect_value(t, mismatched.refusal, Replay_Refusal.Identity_Mismatch)
}

@(test)
test_seedfix_live_run_and_refold_have_identical_digests :: proc(t: ^testing.T) {
	// A live run through the production seam (run_startup_rooted + step_tick(&rng)) and
	// the re-fold of its recorded log yield bit-identical per-tick AND session frame
	// digests. The two captures share only the artifact, the recorded snapshots, and the
	// seed; the re-fold substitutes nothing but the input source while re-feeding the
	// SAME seed. Equal digests prove the live seam and the re-fold seam agree for a
	// seedless-setup uses_rng game — the run_startup_rooted path reproduces.
	context.allocator = context.temp_allocator
	live_program, ok := load_seedfix_golden(t)
	if !ok {
		return
	}
	inputs := seedfix_golden_inputs()
	live := seedfix_live_capture(&live_program, inputs, SEEDFIX_GOLDEN_SEED)

	log_bytes := record_seedfix_golden_session(&live_program, inputs, SEEDFIX_GOLDEN_SEED)
	log, parse_ok := read_replay(log_bytes)
	if !testing.expect(t, parse_ok) {
		return
	}
	refold_program, refold_ok := load_seedfix_golden(t)
	if !refold_ok {
		return
	}
	result := replay_capture(
		&refold_program,
		SEEDFIX_GOLDEN_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SEEDFIX_GOLDEN_SEED),
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
test_regenerate_seedfix_golden_fixtures :: proc(t: ^testing.T) {
	// Regeneration is armed only by FUNPACK_REGEN_GOLDEN — an ordinary test pass SKIPS
	// this, so the committed fixtures are never silently rewritten. When armed, it
	// records the scripted session through the production recorder (the resolved root
	// seed pinned in the v2 header), writes the byte-stable log to
	// testdata/seedfix_golden.replay, re-folds it through the capturing driver under the
	// SAME seed, and writes the session digest (decimal u64) to
	// testdata/seedfix_golden.digest — both relative to the runtime/ cwd. Commit both.
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) == "" {
		return
	}
	context.allocator = context.temp_allocator
	program, ok := load_seedfix_golden(t)
	if !ok {
		return
	}
	inputs := seedfix_golden_inputs()
	log_bytes := record_seedfix_golden_session(&program, inputs, SEEDFIX_GOLDEN_SEED)

	log_path, log_join_err := filepath.join({"testdata", "seedfix_golden.replay"})
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
		SEEDFIX_GOLDEN_ARTIFACT,
		log,
		context.temp_allocator,
		seeded_run(SEEDFIX_GOLDEN_SEED),
	)
	if !testing.expect_value(t, result.refusal, Replay_Refusal.None) {
		return
	}

	digest_buf: [20]byte
	digest_text := strconv.write_uint(digest_buf[:], result.capture.session, 10)
	digest_path, digest_join_err := filepath.join({"testdata", "seedfix_golden.digest"})
	if !testing.expect(t, digest_join_err == nil) {
		return
	}
	testing.expect(t, os.write_entire_file_from_string(digest_path, digest_text) == nil)
}
