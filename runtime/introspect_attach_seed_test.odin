package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:testing"

@(private = "file")
SEEDOPEN_NORNG_FIXTURE :: "funpack-artifact 19\n" +
	"[meta 2]\n" +
	"project introspect\n" +
	"version L5:0.1.0\n" +
	"[data 0]\n" +
	"[things 1]\n" +
	"thing Hero false 0 1\n" +
	"field pos Fixed =0\n" +
	"[behaviors 1]\n" +
	"behavior advance on:Hero stage:control contract:Update 0 1 1 1\n" +
	"param self Hero\n" +
	"emit Hero\n" +
	"node return 1\n" +
	"node with 1 2\n" +
	"node name self 0\n" +
	"node recfield pos 1\n" +
	"node binary add 2\n" +
	"node field pos 1\n" +
	"node name self 0\n" +
	"node fixed 4294967296 0\n" +
	"[pipeline_flattened 1]\n" +
	"step 0 stage:control behavior:advance\n" +
	"[setup 1]\n" +
	"spawn Hero 0\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Intro tick_hz:60 logical:160x120 bindings:bindings\n"

@(private = "file")
seedopen_write_fixture :: proc(t: ^testing.T, name: string, contents: string) -> string {
	dir, dir_err := os.temp_dir(context.temp_allocator)
	testing.expect(t, dir_err == nil, "a temp dir is available")
	path, join_err := filepath.join({dir, name}, context.temp_allocator)
	testing.expect(t, join_err == nil, "the fixture path joins")
	testing.expect(t, os.write_entire_file_from_string(path, contents) == nil, "the fixture writes")
	return path
}

@(private = "file")
seedopen_reference_fold :: proc(
	program: ^Program,
	snapshots: []Input,
	seed: Run_Seed,
	allocator := context.allocator,
) -> Frame_Capture {
	world := new_world(program^, allocator)
	base := initial_version(world, allocator)
	tick_hz := program.entrypoint.tick_hz
	per_tick := make([dynamic]Frame_Digest, 0, len(snapshots), allocator)

	if seed.has_seed {
		version, rng := run_startup_rooted(program, base, seed.seed, allocator)
		current := rng
		for snapshot, i in snapshots {
			time := time_resource_at(tick_hz, i, allocator)
			version = step_tick(program, version, snapshot, time, allocator, &current)
			draw := render_version(program, version, snapshot, time, allocator)
			append(&per_tick, capture_frame(version, draw, allocator))
		}
		return finish_capture(per_tick[:], allocator)
	}

	version := run_startup(program, base, allocator)
	for snapshot, i in snapshots {
		time := time_resource_at(tick_hz, i, allocator)
		version = step_tick(program, version, snapshot, time, allocator)
		draw := render_version(program, version, snapshot, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}

@(test)
test_open_session_for_artifact_bare_seeds_uses_rng :: proc(t: ^testing.T) {
	path := seedopen_write_fixture(t, "funpack-open-session-bare-seed.artifact", SEEDFIX_GOLDEN_ARTIFACT)
	defer os.remove(path)

	session, program, result := open_session_for_artifact(path, "", false, context.allocator)
	testing.expect_value(t, result, Open_Session_Result.Ok)
	testing.expect(t, program != nil, "an Ok open returns the heap program the session borrows")
	s := session

	testing.expect(t, program_uses_rng(program), "the fixture is the uses_rng shape the fix targets")
	testing.expect(t, !program_is_seeded(program), "the fixture's setup is seedless — the harder per-tick-draw case")

	testing.expect(t, s.seed.has_seed, "a bare open of a uses_rng game resolves a root seed (seeded=true)")
	testing.expect_value(t, s.seed.seed, RUNTIME_DEFAULT_SEED)
	testing.expect_value(t, len(s.snapshots), ATTACH_FRESH_TICKS)

	bare := session_capture(&s)
	seeded_ref := seedopen_reference_fold(program, s.snapshots, seeded_run(RUNTIME_DEFAULT_SEED), context.allocator)
	seedless_ref := seedopen_reference_fold(program, s.snapshots, NO_SEED, context.allocator)
	testing.expect_value(t, bare.session, seeded_ref.session)
	testing.expect(
		t,
		bare.session != seedless_ref.session,
		"the bare open threads the real root seed — its committed run differs from a seedless open's",
	)
}

@(test)
test_open_session_for_artifact_bare_seed_override :: proc(t: ^testing.T) {
	path := seedopen_write_fixture(t, "funpack-open-session-override.artifact", SEEDFIX_GOLDEN_ARTIFACT)
	defer os.remove(path)

	OVERRIDE :: i64(0x00C0FFEE)
	session, program, result := open_session_for_artifact(path, "", false, context.allocator, OVERRIDE)
	testing.expect_value(t, result, Open_Session_Result.Ok)
	s := session

	testing.expect(t, s.seed.has_seed, "an overridden bare open is seeded")
	testing.expect_value(t, s.seed.seed, OVERRIDE)
	testing.expect(t, s.seed.seed != RUNTIME_DEFAULT_SEED, "the override replaces the default seed")

	default_session, _, _ := open_session_for_artifact(path, "", false, context.allocator)
	over := session_capture(&s)
	deflt := session_capture(&default_session)
	testing.expect(t, over.session != deflt.session, "a different seed yields a different committed run")
	_ = program
}

@(test)
test_open_session_for_artifact_bare_no_rng_stays_seedless :: proc(t: ^testing.T) {
	path := seedopen_write_fixture(t, "funpack-open-session-norng.artifact", SEEDOPEN_NORNG_FIXTURE)
	defer os.remove(path)

	session, program, result := open_session_for_artifact(path, "", false, context.allocator)
	testing.expect_value(t, result, Open_Session_Result.Ok)
	s := session
	testing.expect(t, !program_uses_rng(program), "the fixture draws no RNG")
	testing.expect(t, !s.seed.has_seed, "a bare open of a no-RNG game stays seedless (NO_SEED)")
}

@(test)
test_open_session_for_artifact_seeded_replay_folds_recorded_run :: proc(t: ^testing.T) {
	artifact := seedopen_write_fixture(t, "funpack-open-session-seeded-replay.artifact", SEEDFIX_GOLDEN_ARTIFACT)
	defer os.remove(artifact)
	replay_path := seedopen_write_fixture(t, "funpack-open-session-seeded.replay", SEEDFIX_GOLDEN_LOG)
	defer os.remove(replay_path)

	session, program, result := open_session_for_artifact(artifact, replay_path, true, context.allocator)
	testing.expect_value(t, result, Open_Session_Result.Ok)
	testing.expect(t, program != nil, "an Ok open returns the heap program")
	s := session

	testing.expect(t, s.seed.has_seed, "attach over a seeded replay folds the recorded seed (seeded=true)")
	testing.expect_value(t, s.seed.seed, RUNTIME_DEFAULT_SEED)
	testing.expect(t, len(s.snapshots) > 0, "the recorded ticks were folded")
	testing.expect(t, len(s.snapshots) != ATTACH_FRESH_TICKS, "the session navigates the recording, not the fresh-open window")

	over_replay := session_capture(&s)
	reference := seedopen_reference_fold(program, s.snapshots, seeded_run(RUNTIME_DEFAULT_SEED), context.allocator)
	testing.expect_value(t, over_replay.session, reference.session)
}
