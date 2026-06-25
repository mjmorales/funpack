// The headless scripted-record round-trip spec (replay_scripted.odin): a log produced
// by record_scripted is byte-stable, re-readable, and re-folds bit-identically through
// the production identity-gated driver — the determinism warranty for the agent-drivable
// record path, proved over the three seed classes the live recorder spans:
//
//   - SEEDLESS (pong — Input is the sole nondeterminism source): record_scripted with no
//     override pins has_seed=false, and the log re-folds under NO_SEED to the same world a
//     direct seedless fold of the same snapshots commits.
//   - USES_RNG, SEEDLESS SETUP (seedfix — the uses_rng seedless-setup case, §25 §60): a game
//     whose setup binds no Rng but whose per-tick behavior draws is recorded SEEDED (the
//     gate is program_uses_rng, not program_is_seeded), so the resolved root seed rides the
//     header and the log re-folds seeded to the same world a direct run_startup_rooted fold
//     commits. This is the record path's core property: an agent can bootstrap a navigable
//     SEEDED timeline headlessly, where an interactive SDL session is otherwise required.
//   - SEED IS RECORDED, NOT AMBIENT (§01 §50, §25 §60): the header's seed gates the re-fold —
//     a `seed` override pins it (overriding the config/default precedence), and re-folding
//     under a different seed (or seedless) is refused by the identity gate.
//
// These exercise the REAL recorder → reader → driver path: record_scripted → read_replay →
// replay, the same three layers the production attach-over-replay open drives, so the test
// is the living spec of the record junction, not a bug-specific check.
package funpack_runtime

import "core:testing"

// SCRIPTED_SEEDLESS_ARTIFACT is the committed seedless pong artifact (Input is its sole
// nondeterminism source — no behavior binds an Rng), embedded so the seedless round-trip
// runs with no filesystem. record_scripted must record it has_seed=false.
SCRIPTED_SEEDLESS_ARTIFACT := #load("testdata/pong.artifact", string)

// SCRIPTED_USES_RNG_ARTIFACT is the committed seedfix artifact: a game whose SETUP is
// seedless (program_is_seeded false) but whose PER-TICK behavior draws from the engine Rng
// (program_uses_rng true) — the uses_rng seedless-setup shape. record_scripted must record it
// SEEDED (the uses_rng gate), pinning the resolved root seed in the header so the recorded
// run re-folds seeded instead of rendering black.
SCRIPTED_USES_RNG_ARTIFACT := #load("testdata/seedfix.artifact", string)

// scripted_flatten expands a segment list into the flat per-tick snapshot stream
// record_scripted records — each segment's snapshot repeated `ticks` times, in order — so a
// direct fold can re-feed exactly what the log carries and the worlds are comparable.
@(private = "file")
scripted_flatten :: proc(segments: []Scripted_Segment, allocator := context.allocator) -> []Input {
	flat := make([dynamic]Input, 0, allocator)
	for segment in segments {
		for _ in 0 ..< segment.ticks {
			append(&flat, segment.snapshot)
		}
	}
	return flat[:]
}

// scripted_direct_seedless_fold folds a snapshot stream over a fresh seedless run the way
// replay_refold does (run_startup + step_tick, Time bound once via time_resource), so its
// committed world is the reference the log's NO_SEED re-fold must equal.
@(private = "file")
scripted_direct_seedless_fold :: proc(program: ^Program, snapshots: []Input, allocator := context.allocator) -> World_Version {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	time := time_resource(program.entrypoint.tick_hz, allocator)
	for snapshot in snapshots {
		version = step_tick(program, version, snapshot, time, allocator)
	}
	return version
}

// scripted_direct_seeded_fold folds a snapshot stream over a fresh run restarted FROM the
// recorded seed the way replay_refold's seeded arm does (run_startup_rooted + step_tick
// threading the persistent Rng), so its committed world is the reference the log's seeded
// re-fold must equal — the seed-driven spawns reproduced.
@(private = "file")
scripted_direct_seeded_fold :: proc(program: ^Program, snapshots: []Input, seed: i64, allocator := context.allocator) -> World_Version {
	world := new_world(program^, allocator)
	version, rng := run_startup_rooted(program, initial_version(world, allocator), seed, allocator)
	current := rng
	time := time_resource(program.entrypoint.tick_hz, allocator)
	for snapshot in snapshots {
		version = step_tick(program, version, snapshot, time, allocator, &current)
	}
	return version
}

@(test)
test_record_scripted_seedless_roundtrips :: proc(t: ^testing.T) {
	// A seedless game's scripted record pins has_seed=false, re-reads to the same snapshot
	// count, and re-folds under NO_SEED to the world a direct seedless fold commits — the
	// round-trip warranty for the Input-only nondeterminism class.
	context.allocator = context.temp_allocator
	program, load_err := load_program(SCRIPTED_SEEDLESS_ARTIFACT, context.allocator)
	if !testing.expect_value(t, load_err, Artifact_Error.None) {
		return
	}
	testing.expect(t, !program_uses_rng(&program), "pong draws no RNG — the seedless class")

	segments := []Scripted_Segment{{snapshot = empty(), ticks = 4}, {snapshot = empty(), ticks = 3}}
	log_bytes, summary := record_scripted(&program, SCRIPTED_SEEDLESS_ARTIFACT, nil, segments)
	testing.expect_value(t, summary.has_seed, false)
	testing.expect_value(t, summary.tick_count, 7)

	log, read_ok := read_replay(log_bytes)
	testing.expect(t, read_ok, "the recorded seedless log re-reads")
	testing.expect_value(t, len(log.snapshots), 7)
	testing.expect_value(t, log.identity.has_seed, false)

	result := replay(&program, SCRIPTED_SEEDLESS_ARTIFACT, log, context.allocator, NO_SEED)
	testing.expect_value(t, result.refusal, Replay_Refusal.None)

	want := scripted_direct_seedless_fold(&program, scripted_flatten(segments))
	testing.expect(t, world_versions_equal(result.world, want), "the seedless re-fold equals a direct fold of the same snapshots")
}

@(test)
test_record_scripted_uses_rng_seedless_setup_roundtrips_seeded :: proc(t: ^testing.T) {
	// THE uses_rng SEEDLESS-SETUP CASE: a uses_rng game with a seedless setup is recorded
	// SEEDED — the resolved root seed (the fixed engine default here, since seedfix bakes no
	// config seed and no override is passed) rides the header, so the log re-folds seeded to
	// the world a direct run_startup_rooted fold commits, AND re-folding it under NO_SEED is
	// refused (the seed is recorded determinism input, not ambient). A headless scripted
	// record produces this seeded recording an interactive SDL session is otherwise needed for.
	context.allocator = context.temp_allocator
	program, load_err := load_program(SCRIPTED_USES_RNG_ARTIFACT, context.allocator)
	if !testing.expect_value(t, load_err, Artifact_Error.None) {
		return
	}
	testing.expect(t, program_uses_rng(&program), "seedfix draws RNG per tick — the uses_rng class")
	testing.expect(t, !program_is_seeded(&program), "seedfix's setup is seedless — the seedless-setup shape")

	segments := []Scripted_Segment{{snapshot = empty(), ticks = 5}}
	log_bytes, summary := record_scripted(&program, SCRIPTED_USES_RNG_ARTIFACT, nil, segments)
	testing.expect_value(t, summary.has_seed, true)
	testing.expect_value(t, summary.seed, RUNTIME_DEFAULT_SEED)
	testing.expect_value(t, summary.tick_count, 5)

	log, read_ok := read_replay(log_bytes)
	testing.expect(t, read_ok, "the recorded seeded log re-reads")
	testing.expect_value(t, log.identity.has_seed, true)
	testing.expect_value(t, log.identity.seed, RUNTIME_DEFAULT_SEED)

	// Re-fold under the recorded seed: clean, and bit-identical to a direct seeded fold.
	seeded := replay(&program, SCRIPTED_USES_RNG_ARTIFACT, log, context.allocator, seeded_run(RUNTIME_DEFAULT_SEED))
	testing.expect_value(t, seeded.refusal, Replay_Refusal.None)
	want := scripted_direct_seeded_fold(&program, scripted_flatten(segments), RUNTIME_DEFAULT_SEED)
	testing.expect(t, world_versions_equal(seeded.world, want), "the seeded re-fold reproduces the seed-driven run")

	// The seed is RECORDED: re-folding the seeded log under NO_SEED is refused by the gate.
	seedless := replay(&program, SCRIPTED_USES_RNG_ARTIFACT, log, context.allocator, NO_SEED)
	testing.expect_value(t, seedless.refusal, Replay_Refusal.Identity_Mismatch)
}

@(test)
test_record_scripted_seed_override_pins_header :: proc(t: ^testing.T) {
	// An explicit `seed` override takes the top of the §25 §60 precedence: it pins the
	// header seed over the config/default, so the log re-folds only under THAT seed and the
	// engine-default seed is refused — proving the override threads through and the seed
	// gate distinguishes runs by their recorded seed.
	context.allocator = context.temp_allocator
	program, load_err := load_program(SCRIPTED_USES_RNG_ARTIFACT, context.allocator)
	if !testing.expect_value(t, load_err, Artifact_Error.None) {
		return
	}
	override := i64(0xC0FFEE)
	segments := []Scripted_Segment{{snapshot = empty(), ticks = 3}}
	log_bytes, summary := record_scripted(&program, SCRIPTED_USES_RNG_ARTIFACT, override, segments)
	testing.expect_value(t, summary.has_seed, true)
	testing.expect_value(t, summary.seed, override)

	log, read_ok := read_replay(log_bytes)
	testing.expect(t, read_ok, "the override-seeded log re-reads")
	testing.expect_value(t, log.identity.seed, override)

	pinned := replay(&program, SCRIPTED_USES_RNG_ARTIFACT, log, context.allocator, seeded_run(override))
	testing.expect_value(t, pinned.refusal, Replay_Refusal.None)
	wrong := replay(&program, SCRIPTED_USES_RNG_ARTIFACT, log, context.allocator, seeded_run(RUNTIME_DEFAULT_SEED))
	testing.expect_value(t, wrong.refusal, Replay_Refusal.Identity_Mismatch)
}

@(test)
test_record_scripted_tick_count_sums_segments :: proc(t: ^testing.T) {
	// The recorded tick count is the sum of the segments' tick counts, and the log re-reads
	// to exactly that many snapshots — the framing's self-describing `[ticks N]` count is the
	// total the script declared, regardless of segment boundaries.
	context.allocator = context.temp_allocator
	program, load_err := load_program(SCRIPTED_SEEDLESS_ARTIFACT, context.allocator)
	if !testing.expect_value(t, load_err, Artifact_Error.None) {
		return
	}
	segments := []Scripted_Segment {
		{snapshot = empty(), ticks = 4},
		{snapshot = empty(), ticks = 1},
		{snapshot = empty(), ticks = 7},
	}
	log_bytes, summary := record_scripted(&program, SCRIPTED_SEEDLESS_ARTIFACT, nil, segments)
	testing.expect_value(t, summary.tick_count, 12)
	log, read_ok := read_replay(log_bytes)
	testing.expect(t, read_ok, "the multi-segment log re-reads")
	testing.expect_value(t, len(log.snapshots), 12)
}
