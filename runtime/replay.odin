// The replay re-fold driver (spec §07 §4, §09 §5, §23 §4): the headless
// execution path that reproduces a recorded run by restarting the artifact and
// re-feeding its recorded per-tick action snapshots. It is the consuming twin of
// the recorder (replay_record.odin) and the reader (replay_log.odin): the reader
// parses a log into an artifact identity plus the ordered Input snapshots, and
// this driver re-folds those snapshots over a freshly-loaded Program.
//
// THE ONLY SUBSTITUTION IS THE INPUT SOURCE. A replay restarts from the SAME seam
// a live run starts from — run_startup applies setup's [Spawn] batch, then the
// existing step_tick fold (tick.odin) advances the world one committed version per
// tick. Population batching, blackboard fold-forward, signal forward-routing, and
// stable-Id intra-stage order are unchanged: the driver supplies the recorded
// Input each tick INSTEAD of resolving live device input, and changes nothing
// else. Input is the sole recorded source of nondeterminism (pong has no RNG, the
// interpreter is the determinism ground truth, §09 §5), so pinning the snapshot
// stream pins the whole replay — the re-fold commits a world bit-identical to the
// original run's, run after run.
//
// THE IDENTITY GATE (§09 §5): before re-folding a single tick the driver verifies
// the log header's pinned artifact identity against the loaded artifact — the
// schema version, the §4 project name and version, the fixed tick rate, AND the
// xxh64 content hash over the artifact's RAW BYTES. A recorded log carries the
// fingerprint of the exact build it ran against; re-folding it against a different
// build would fold the recorded snapshots over the wrong program. The driver
// refuses a mismatch (Replay_Refusal.Identity_Mismatch) with a diagnostic rather
// than silently re-folding the wrong artifact.
//
// HEADLESS: the driver runs with no renderer and no window. The render stage is a
// post-commit draw-list projection (render.odin) the per-tick fold already skips,
// so a re-fold needs no frame surface to advance the world — it terminates when
// the recorded snapshot stream is exhausted. runtime/** never imports funpack/**;
// the artifact bytes are the only sanctioned coupling (§29, §09).
package funpack_runtime

import "core:fmt"

// Replay_Refusal is the closed set of reasons the replay driver refuses to
// re-fold a log. None is the success arm (the re-fold ran to the recorded tick
// count); Identity_Mismatch is the §09 §5 gate firing — the log's pinned artifact
// identity does not match the loaded artifact, so re-folding it would fold the
// recorded snapshots over the wrong program.
Replay_Refusal :: enum {
	None,
	Identity_Mismatch,
}

// Replay_Result is the outcome of a re-fold: the refusal arm, the final committed
// world version (the bit-identity comparison surface — meaningful only when
// refusal is None), and a human-readable diagnostic the caller can surface. On a
// refusal the world is the empty zero value, since no tick was folded.
Replay_Result :: struct {
	refusal:   Replay_Refusal,
	world:     World_Version,
	diagnostic: string,
}

// Run_Seed declares the tick-0 RNG seed the CALLER is starting the re-fold's run
// under — the run-time determinism input that is NOT in the artifact (§25 §60). It
// is the seed half of the identity gate: a recorded log's pinned seed must equal
// the seed the run is started under, or the re-fold is refused (a seed change
// yields a different recorded identity, §01 §50). NO_SEED is the seedless run
// (pong, hunt — Input is the sole nondeterminism source, Lore #7); seeded_run
// declares a seed. The default arg is NO_SEED, so every existing seedless caller is
// unchanged.
Run_Seed :: struct {
	has_seed: bool,
	seed:     i64,
}

// NO_SEED is the seedless run declaration — the pong/hunt default. It pins
// has_seed = false so the gate refuses a seeded log against a seedless run.
NO_SEED :: Run_Seed{has_seed = false, seed = 0}

// seeded_run declares a re-fold started under a specific tick-0 seed (snake). The
// gate compares this seed against the log's recorded seed, so re-folding under a
// different seed than the log was recorded with is refused.
seeded_run :: proc(seed: i64) -> Run_Seed {
	return Run_Seed{has_seed = true, seed = seed}
}

// replay re-folds a parsed log against a freshly-loaded artifact STARTED UNDER the
// declared run seed, returning the final committed world version. It FIRST verifies
// the log header's pinned identity against the loaded run identity — the build
// fingerprint derived from the raw artifact bytes PLUS the declared run seed (§09
// §5, §25 §60); a build mismatch OR a seed mismatch is refused with a diagnostic
// and NO tick is folded. On a match it restarts the artifact FROM THE RECORDED SEED
// (run_startup_seeded when seeded, the bare run_startup [Spawn] batch when seedless),
// then drives the existing step_tick fold once per recorded snapshot, supplying that
// tick's recorded Input instead of resolving live input. The world it commits is
// bit-identical to the original run's (world_versions_equal), since Input + the
// tick-0 seed are the recorded determinism inputs.
//
// The artifact_bytes MUST be the exact bytes load_program parsed `program` from
// (load_artifact_file discards them, so the caller re-reads the file or retains
// the bytes it loaded from) — the content hash is over those raw bytes, so a
// recompute over different bytes would spuriously refuse a matching build. The
// run_seed defaults to NO_SEED, so a seedless caller (pong, hunt) is unchanged.
replay :: proc(
	program: ^Program,
	artifact_bytes: string,
	log: Replay_Log,
	allocator := context.allocator,
	run_seed: Run_Seed = NO_SEED,
) -> Replay_Result {
	loaded_identity := loaded_run_identity(program^, artifact_bytes, run_seed)
	if !replay_identity_matches(log.identity, loaded_identity) {
		return Replay_Result {
			refusal = .Identity_Mismatch,
			diagnostic = replay_mismatch_diagnostic(log.identity, loaded_identity, allocator),
		}
	}

	world := replay_refold(program, log.identity, log.snapshots, allocator)
	return Replay_Result{refusal = .None, world = world}
}

// loaded_run_identity builds the identity the gate compares the recorded log
// against: the build fingerprint from the artifact bytes, with the CALLER's
// declared run seed folded in. The seed is a run-time input, not derivable from the
// program, so the gate learns it from the caller — a seeded re-fold passes the seed
// it intends to run under, and the gate refuses a log recorded under a different one.
@(private = "file")
loaded_run_identity :: proc(
	program: Program,
	artifact_bytes: string,
	run_seed: Run_Seed,
) -> Replay_Identity {
	if run_seed.has_seed {
		return identity_from_program_seeded(program, artifact_bytes, run_seed.seed)
	}
	return identity_from_program(program, artifact_bytes)
}

// replay_refold restarts the artifact FROM THE RECORDED SEED and re-feeds the
// recorded snapshots over the existing tick loop — the execution path the identity
// gate guards. It runs the SAME setup + step_tick seam a live run uses, routed by
// whether the recorded identity carries a root seed:
//
//   - SEEDED (any uses_rng game): run_startup_rooted restarts from the recorded
//     tick-0 seed and retains the root Rng (advanced past setup when setup itself
//     draws, as in snake's first food cell; the bare seed Rng when setup is seedless
//     but per-tick behaviors draw); each tick threads that persistent Rng through
//     step_tick(&rng), so the re-fold re-feeds the EXACT seed and reproduces every
//     RNG-driven spawn (§25 §60, §04 §1) — the determinism warranty starts at the
//     root seed, so a re-fold that ignored it would diverge.
//   - SEEDLESS (pong, hunt — no RNG): bare run_startup applies the pre-evaluated
//     [Spawn] batch and step_tick threads no Rng.
//
// has_seed gates the ROOT-SEED threading, not the startup shape: run_startup_rooted
// chooses run_startup_seeded vs run_startup internally by program_is_seeded, so a
// seedless-setup uses_rng game (recorded has_seed=true) re-folds correctly instead of
// being fed to run_startup_seeded over a setup that returns no Rng.
//
// Either way each tick's Input comes from the recorded snapshot rather than live
// resolution, the only substitution; it terminates when the stream is exhausted,
// returning the final committed version (the comparison surface). The Time resource
// is derived once from the artifact's fixed tick rate.
@(private = "file")
replay_refold :: proc(
	program: ^Program,
	identity: Replay_Identity,
	snapshots: []Input,
	allocator := context.allocator,
) -> World_Version {
	world := new_world(program^, allocator)
	base := initial_version(world, allocator)
	time := time_resource(program.entrypoint.tick_hz, allocator)

	if identity.has_seed {
		version, rng := run_startup_rooted(program, base, identity.seed, allocator)
		current := rng
		for snapshot in snapshots {
			version = step_tick(program, version, snapshot, time, allocator, &current)
		}
		return version
	}

	version := run_startup(program, base, allocator)
	for snapshot in snapshots {
		version = step_tick(program, version, snapshot, time, allocator)
	}
	return version
}

// Replay_Capture_Result is the outcome of a CAPTURING re-fold: the same refusal
// arm replay returns, plus the per-tick + session frame digests folded over every
// committed re-fold tick (meaningful only when refusal is None). It is what the
// acceptance harness compares against a live run's capture and what the cross-build
// golden-log assertion compares against the committed expected session digest. On a
// refusal the capture is the zero value, since no tick was folded.
Replay_Capture_Result :: struct {
	refusal:    Replay_Refusal,
	capture:    Frame_Capture,
	diagnostic: string,
}

// replay_capture re-folds a parsed log through the SAME identity-gated production
// path replay uses, but captures the deterministic per-tick frame digest (over the
// committed world state and its §20 draw-list) of every re-fold tick and folds the
// session digest over them (§20, §28, §07 §4). It is the headless digest
// entrypoint the acceptance harness and the operator gate both drive: a live run's
// captured session digest and this re-fold's must be bit-identical, and a committed
// golden log re-folded here on any build must reproduce the committed expected
// session digest. The identity gate fires FIRST (a mismatched build is refused with
// a diagnostic and no tick captured, §09 §5); on a match each committed re-fold tick
// is digested over its world state and projected draw-list, the same surface a live
// capture digests. The artifact_bytes MUST be the exact bytes load_program parsed
// `program` from, since the gate's content hash is over those raw bytes. The
// run_seed declares the tick-0 seed the re-fold is started under (default NO_SEED);
// the gate refuses a log recorded under a different seed, and the seeded capture
// restarts from the recorded seed so the digested committed state reproduces.
replay_capture :: proc(
	program: ^Program,
	artifact_bytes: string,
	log: Replay_Log,
	allocator := context.allocator,
	run_seed: Run_Seed = NO_SEED,
) -> Replay_Capture_Result {
	loaded_identity := loaded_run_identity(program^, artifact_bytes, run_seed)
	if !replay_identity_matches(log.identity, loaded_identity) {
		return Replay_Capture_Result {
			refusal = .Identity_Mismatch,
			diagnostic = replay_mismatch_diagnostic(log.identity, loaded_identity, allocator),
		}
	}
	return Replay_Capture_Result {
		refusal = .None,
		capture = refold_capture(program, log.identity, log.snapshots, allocator),
	}
}

// refold_capture restarts the artifact FROM THE RECORDED SEED and re-feeds the
// recorded snapshots over the existing tick loop — the SAME seam replay_refold uses
// (run_startup_rooted + step_tick(&rng) when the identity carries a seed, bare
// run_startup + seedless step_tick otherwise) — while capturing each committed
// tick's frame digest over the world state and its §20 draw-list, then folds the
// session digest. The render projection (render.odin) runs per committed tick purely
// to build the digest surface; it perturbs no committed state (it is an OBSERVE-class
// projection reading a committed version), so capturing leaves the re-fold's
// committed world unchanged from replay_refold's. The committed state digested here
// already reflects every RNG-driven spawn, so the frame digest needs no seed-aware
// surface — re-feeding the seed at setup is what makes that state reproduce.
@(private = "file")
refold_capture :: proc(
	program: ^Program,
	identity: Replay_Identity,
	snapshots: []Input,
	allocator := context.allocator,
) -> Frame_Capture {
	world := new_world(program^, allocator)
	base := initial_version(world, allocator)
	tick_hz := program.entrypoint.tick_hz
	per_tick := make([dynamic]Frame_Digest, 0, len(snapshots), allocator)

	// Time rebinds per committed tick so `time.t` advances (logical time since
	// startup) — krognid's pose_idle bob reads it. The SAME derivation feeds the
	// live capture (krognid_live_capture), so the render digest is bit-identical
	// across live and re-fold. A control-only game ignores `t`, so this is
	// byte-identical to the prior single-bind path for pong/snake/hunt/yard.
	if identity.has_seed {
		version, rng := run_startup_rooted(program, base, identity.seed, allocator)
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

// replay_identity_matches reports whether a recorded log's pinned identity equals
// the loaded run's identity in EVERY field the gate guards: the artifact schema
// version, the §4 project name and version, the fixed tick rate, the xxh64 content
// hash over the raw artifact bytes (§09 §5 BUILD identity), AND the tick-0 RNG
// seed (§25 §60 determinism INPUT). A single differing field means the log was
// recorded against a different build OR a different seed, so the re-fold is
// refused. The seed is matched on BOTH `has_seed` and `seed`: a seedless log
// (has_seed = false) refuses a seeded run and vice versa, and two seeded runs with
// different seeds refuse each other — the seed is recorded determinism input, so a
// seed change yields a different recorded identity (§01 §50).
@(private = "file")
replay_identity_matches :: proc(recorded, loaded: Replay_Identity) -> bool {
	return(
		recorded.artifact_schema_version == loaded.artifact_schema_version &&
		recorded.project_name == loaded.project_name &&
		recorded.project_version == loaded.project_version &&
		recorded.tick_hz == loaded.tick_hz &&
		recorded.content_hash == loaded.content_hash &&
		recorded.has_seed == loaded.has_seed &&
		recorded.seed == loaded.seed \
	)
}

// replay_mismatch_diagnostic renders the identity gate's refusal into a
// human-readable line naming the recorded vs loaded fingerprint — the §09 §5
// "refuse with a diagnostic" surface. The content hash is the build-specific field
// and the seed is the run-specific determinism input, so the line carries both:
// the two hashes show which BUILD the log was recorded against and the two
// `seed=…` views (a `none` rendering for a seedless run) show which SEED, so a
// reader sees whether the refusal is a wrong build or a wrong seed. The string is
// allocated on the passed allocator and owned by the caller.
@(private = "file")
replay_mismatch_diagnostic :: proc(
	recorded, loaded: Replay_Identity,
	allocator := context.allocator,
) -> string {
	return fmt.aprintf(
		"replay refused: log recorded against %s %s (schema %d, tick_hz %d, hash %d, %s) " +
		"but loaded run is %s %s (schema %d, tick_hz %d, hash %d, %s)",
		recorded.project_name,
		recorded.project_version,
		recorded.artifact_schema_version,
		recorded.tick_hz,
		recorded.content_hash,
		seed_diagnostic(recorded, allocator),
		loaded.project_name,
		loaded.project_version,
		loaded.artifact_schema_version,
		loaded.tick_hz,
		loaded.content_hash,
		seed_diagnostic(loaded, allocator),
		allocator = allocator,
	)
}

// seed_diagnostic renders an identity's tick-0 seed for the refusal line: `seed=N`
// for a seeded run, `seed=none` for a seedless one (pong/hunt). Rendering the
// boolean explicitly is what lets a reader tell a seedless log from one seeded
// with 0 — the same distinction the gate makes (a value sentinel could not).
@(private = "file")
seed_diagnostic :: proc(identity: Replay_Identity, allocator := context.allocator) -> string {
	if !identity.has_seed {
		return "seed=none"
	}
	return fmt.aprintf("seed=%d", identity.seed, allocator = allocator)
}

// time_dt derives the §04 fixed frame delta from the artifact's fixed tick rate:
// dt = 1/tick_hz in Q32.32 through the kernel — no float, identical bits every
// machine (§10). A non-positive tick rate folds to a zero dt rather than dividing
// by zero (a malformed entrypoint the loader would have refused). The one dt
// derivation every driver shares, so a live run / re-fold / golden capture cannot
// fork their delta.
time_dt :: proc(tick_hz: int) -> Fixed {
	if tick_hz > 0 {
		return fixed_div(to_fixed(1), to_fixed(i64(tick_hz)))
	}
	return Fixed(0)
}

// time_resource builds the Time resource a driver binds for the SESSION (engine.core
// `data Time { dt: Fixed, t: Fixed }`): the fixed `dt` (time_dt) and the logical
// time `t` at the session start, ZERO (spec §04: `t` is logical time since startup,
// the same zero a `Time.at(dt)` test double seeds). It is the SINGLE Time derivation
// every driver shares — the replay re-fold (control-only, never reads `t`), the live
// SDL session, and the golden-capture harnesses all bind Time through here, so the
// derivation cannot fork per driver. A driver that RENDERS a `time.t`-reading body
// (krognid's pose_idle bob) rebinds the per-tick `t` through time_resource_at; a
// control-only path uses this session resource (its t=0 is unread by every control
// behavior, which reads only `dt`).
time_resource :: proc(tick_hz: int, allocator := context.allocator) -> Record_Value {
	return time_resource_at(tick_hz, 0, allocator)
}

// time_resource_at builds the Time resource AT a committed tick: `dt` as ever, and
// `t` = tick * dt — the §04 logical time since startup, accumulated in exact
// fixed-point (tick * dt, the closed-form sum of a constant dt, so no per-tick
// rounding drift). The first committed tick (index 0) reads t=0, matching the
// session-start seed and the `Time.at(dt)` double, and `t` advances one dt per tick
// thereafter. krognid's draw_krognid reads `time.t` (pose_idle's breathing bob over
// logical time); the SAME derivation feeds the live capture and the production
// re-fold, so the `t`-driven idle pose is bit-identical across them (the render
// digest cannot fork). Control behaviors read only `dt`, so a per-tick `t` never
// perturbs committed state; a non-`t`-reading render body (pong/snake/hunt/yard)
// digests byte-identically whether t is 0 or advancing (it never reads the field).
time_resource_at :: proc(tick_hz: int, tick: int, allocator := context.allocator) -> Record_Value {
	dt := time_dt(tick_hz)
	fields := make(map[string]Value, allocator)
	fields["dt"] = dt
	fields["t"] = fixed_mul(dt, to_fixed(i64(tick)))
	return Record_Value{type_name = "Time", fields = fields}
}
