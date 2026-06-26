// The BARE-OPEN SEED-CONTRACT acceptance for the shared session opener
// (open_session_for_artifact, introspect_attach.odin) — the friction-7dfc0512 /
// friction-9fcfe1cd root-cause fix proven as living spec. The §28 debug surface could
// not surface a `uses_rng` game's live runtime state: a BARE attach (no replay log)
// opened SEEDLESS, so the RNG-driven behaviors folded with no threaded root Rng and the
// session reported seeded=false with frozen/degenerate state — a black-screen render bug
// was undiagnosable through the agentic debug path. The fix makes a bare open of a
// uses_rng program resolve the SAME §25 §60 root seed `funpack run`/`live` resolve, so a
// bare attach reproduces the EXACT seeded run the SDL window shows.
//
// The fixture is SEEDFIX_GOLDEN_ARTIFACT (seedfix_golden_test.odin) — the deepseed shape
// the friction hit: a SEEDLESS setup whose PER-TICK behavior draws from the engine Rng
// (program_is_seeded false, program_uses_rng true). It is the hardest case, where a gate
// keyed on setup-seeding would still classify the run seedless.
//
// Three bare-open properties + one replay-over-seeded-run property are pinned:
//
//   - BARE SEEDS: a bare open of a uses_rng game reports seeded=true pinned to the
//     resolved default seed (the friction's seeded=false → true flip), and its committed
//     run is bit-identical to a default-seed reference fold yet DEMONSTRABLY DIFFERENT
//     from a seedless (NO_SEED) fold — the surfaced state is the real run, not the frozen
//     seedless state the friction saw.
//   - SEED OVERRIDE: a bare open with an agent-supplied seed (the MCP session_start
//     `seed` arg / `funpack attach --seed`) pins that seed and yields a different
//     committed run than the default — the agent can reproduce a specific run.
//   - NO-RNG UNCHANGED: a bare open of a game that draws no RNG stays seedless (NO_SEED)
//     — the seed is meaningless for it, so the no-RNG path is untouched.
//   - SEEDED REPLAY: attach OVER a recorded seeded run folds the RECORDED seed
//     (seeded=true) and surfaces the real run — the documented remedy that the friction
//     reported still came back seeded=false.
//
// DEFINE-FREE FLOOR: these run in the default `odin test .` build (no FUNPACK_LIVE, no
// SDL) — open_session_for_artifact, the fold, and session_capture are all SDL-free.
package funpack_runtime

import "core:os"
import "core:path/filepath"
import "core:testing"

// SEEDOPEN_NORNG_FIXTURE is a minimal one-behavior artifact (a Hero whose Fixed `pos`
// advances 1.0/tick) that draws NO RNG — inlined per the self-contained-test standard so
// the no-RNG arm stands alone (the package's other no-RNG fixtures are file-private). A
// bare open of it must stay seedless: the seed contract is scoped to uses_rng games.
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

// seedopen_write_fixture writes `contents` (an artifact or a replay log) to a unique
// temp path and returns it. open_session_for_artifact reads from a path, so the seed
// tests need real on-disk inputs; each test gets its own name so they never collide. The
// caller removes the file via the returned path.
@(private = "file")
seedopen_write_fixture :: proc(t: ^testing.T, name: string, contents: string) -> string {
	dir, dir_err := os.temp_dir(context.temp_allocator)
	testing.expect(t, dir_err == nil, "a temp dir is available")
	path, join_err := filepath.join({dir, name}, context.temp_allocator)
	testing.expect(t, join_err == nil, "the fixture path joins")
	testing.expect(t, os.write_entire_file_from_string(path, contents) == nil, "the fixture writes")
	return path
}

// seedopen_reference_fold folds the seedfix run INDEPENDENTLY of the session opener —
// run_startup_rooted (which applies the seedless setup batch and enters tick 0 on the
// bare root Rng) then step_tick(&rng) threading the persistent Rng per tick — capturing
// each committed tick's frame digest. It is the ground truth the bare open must
// reproduce: a NO_SEED fold of the same snapshots yields a DIFFERENT capture, so the
// equality below is the proof the seed was threaded, not vacuous. Mirrors
// seedfix_live_capture, kept local because that one is file-private.
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

// test_open_session_for_artifact_bare_seeds_uses_rng is THE friction fix: a bare open
// (no replay log) of a uses_rng game resolves the §25 §60 default root seed, reports
// seeded=true, and surfaces the REAL default-seeded run — bit-identical to an independent
// default-seed fold and demonstrably different from a seedless fold (the frozen/degenerate
// state the friction saw). The fixture is the seedless-setup, per-tick-RNG shape, so this
// also guards the harder case a setup-seeding gate would misclassify.
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

	// The friction's core flip: seeded is now TRUE, pinned to the resolved default seed —
	// the same value a bare `funpack run` of this artifact records.
	testing.expect(t, s.seed.has_seed, "a bare open of a uses_rng game resolves a root seed (seeded=true)")
	testing.expect_value(t, s.seed.seed, RUNTIME_DEFAULT_SEED)
	testing.expect_value(t, len(s.snapshots), ATTACH_FRESH_TICKS)

	// The bare-seeded session reproduces the real default-seeded run, and is demonstrably
	// NOT the seedless state the friction surfaced.
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

// test_open_session_for_artifact_bare_seed_override pins the agent-supplyable seed (the
// MCP session_start `seed` arg / `funpack attach --seed`): a bare open with an override
// pins THAT seed and yields a different committed run than the default — so an agent can
// reproduce a specific run rather than only the default.
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

	// The override actually threads through the fold: its committed run differs from the
	// default-seed run (a no-op override would collide with the default capture).
	default_session, _, _ := open_session_for_artifact(path, "", false, context.allocator)
	over := session_capture(&s)
	deflt := session_capture(&default_session)
	testing.expect(t, over.session != deflt.session, "a different seed yields a different committed run")
	_ = program
}

// test_open_session_for_artifact_bare_no_rng_stays_seedless pins that the seed contract
// is scoped to uses_rng games: a bare open of a game that draws NO RNG stays NO_SEED, so
// the no-RNG path (pong/hunt-shaped) is untouched.
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

// test_open_session_for_artifact_seeded_replay_folds_recorded_run pins the documented
// remedy (friction-7dfc0512 Part 1): attach OVER a recorded seeded run folds the RECORDED
// seed (seeded=true) and surfaces the real run, NOT the seeded=false the friction
// reported. The committed golden log carries the root seed in its v2 header; opening over
// it reproduces the seeded run bit-identically to a default-seed reference fold of the
// recorded snapshots.
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
	// The recorded snapshots were folded — a real recording, not the fresh-open window.
	testing.expect(t, len(s.snapshots) > 0, "the recorded ticks were folded")
	testing.expect(t, len(s.snapshots) != ATTACH_FRESH_TICKS, "the session navigates the recording, not the fresh-open window")

	// The session surfaces the real recorded seeded run — bit-identical to an independent
	// fold of the recorded snapshots under the recorded seed.
	over_replay := session_capture(&s)
	reference := seedopen_reference_fold(program, s.snapshots, seeded_run(RUNTIME_DEFAULT_SEED), context.allocator)
	testing.expect_value(t, over_replay.session, reference.session)
}
