package funpack_runtime

import "core:testing"

SCRIPTED_SEEDLESS_ARTIFACT := #load("testdata/pong.artifact", string)

SCRIPTED_USES_RNG_ARTIFACT := #load("testdata/seedfix.artifact", string)

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

	seeded := replay(&program, SCRIPTED_USES_RNG_ARTIFACT, log, context.allocator, seeded_run(RUNTIME_DEFAULT_SEED))
	testing.expect_value(t, seeded.refusal, Replay_Refusal.None)
	want := scripted_direct_seeded_fold(&program, scripted_flatten(segments), RUNTIME_DEFAULT_SEED)
	testing.expect(t, world_versions_equal(seeded.world, want), "the seeded re-fold reproduces the seed-driven run")

	seedless := replay(&program, SCRIPTED_USES_RNG_ARTIFACT, log, context.allocator, NO_SEED)
	testing.expect_value(t, seedless.refusal, Replay_Refusal.Identity_Mismatch)
}

@(test)
test_record_scripted_seed_override_pins_header :: proc(t: ^testing.T) {
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
