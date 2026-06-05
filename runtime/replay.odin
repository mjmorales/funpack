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

// replay re-folds a parsed log against a freshly-loaded artifact, returning the
// final committed world version. It FIRST verifies the log header's pinned
// identity against the loaded artifact (derived from the raw artifact bytes the
// program was loaded from); a mismatch is refused with a diagnostic and NO tick
// is folded (§09 §5). On a match it restarts the artifact — run_startup applies
// setup's [Spawn] batch — then drives the existing step_tick fold once per
// recorded snapshot, supplying that tick's recorded Input instead of resolving
// live input. The world it commits is bit-identical to the original run's
// (world_versions_equal), since Input is the sole recorded nondeterminism source.
//
// The artifact_bytes MUST be the exact bytes load_program parsed `program` from
// (load_artifact_file discards them, so the caller re-reads the file or retains
// the bytes it loaded from) — the content hash is over those raw bytes, so a
// recompute over different bytes would spuriously refuse a matching build.
replay :: proc(
	program: ^Program,
	artifact_bytes: string,
	log: Replay_Log,
	allocator := context.allocator,
) -> Replay_Result {
	loaded_identity := identity_from_program(program^, artifact_bytes)
	if !replay_identity_matches(log.identity, loaded_identity) {
		return Replay_Result {
			refusal = .Identity_Mismatch,
			diagnostic = replay_mismatch_diagnostic(log.identity, loaded_identity, allocator),
		}
	}

	world := replay_refold(program, log.snapshots, allocator)
	return Replay_Result{refusal = .None, world = world}
}

// replay_refold restarts the artifact and re-feeds the recorded snapshots over
// the existing tick loop — the execution path the identity gate guards. It runs
// the SAME run_startup + step_tick seam a live run uses; the only difference is
// that each tick's Input comes from the recorded snapshot at that index rather
// than from live input resolution. It terminates when the snapshot stream is
// exhausted, returning the final committed version (the comparison surface). The
// Time resource is derived once from the artifact's fixed tick rate.
@(private = "file")
replay_refold :: proc(
	program: ^Program,
	snapshots: []Input,
	allocator := context.allocator,
) -> World_Version {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	time := replay_time_resource(program.entrypoint.tick_hz, allocator)
	for snapshot in snapshots {
		version = step_tick(program, version, snapshot, time, allocator)
	}
	return version
}

// replay_identity_matches reports whether a recorded log's pinned identity equals
// the loaded artifact's identity in EVERY field §09 §5 gates on: the artifact
// schema version, the §4 project name and version, the fixed tick rate, and the
// xxh64 content hash over the raw artifact bytes. A single differing field means
// the log was recorded against a different build, so the re-fold is refused.
@(private = "file")
replay_identity_matches :: proc(recorded, loaded: Replay_Identity) -> bool {
	return(
		recorded.artifact_schema_version == loaded.artifact_schema_version &&
		recorded.project_name == loaded.project_name &&
		recorded.project_version == loaded.project_version &&
		recorded.tick_hz == loaded.tick_hz &&
		recorded.content_hash == loaded.content_hash \
	)
}

// replay_mismatch_diagnostic renders the identity gate's refusal into a
// human-readable line naming the recorded vs loaded fingerprint — the §09 §5
// "refuse with a diagnostic" surface. The content hash is the build-specific
// field, so the line leads with name/version and the two hashes, the fields a
// reader needs to see which build the log was recorded against. The string is
// allocated on the passed allocator and owned by the caller.
@(private = "file")
replay_mismatch_diagnostic :: proc(
	recorded, loaded: Replay_Identity,
	allocator := context.allocator,
) -> string {
	return fmt.aprintf(
		"replay refused: log recorded against %s %s (schema %d, tick_hz %d, hash %d) " +
		"but loaded artifact is %s %s (schema %d, tick_hz %d, hash %d)",
		recorded.project_name,
		recorded.project_version,
		recorded.artifact_schema_version,
		recorded.tick_hz,
		recorded.content_hash,
		loaded.project_name,
		loaded.project_version,
		loaded.artifact_schema_version,
		loaded.tick_hz,
		loaded.content_hash,
		allocator = allocator,
	)
}

// replay_time_resource builds the Time resource each re-fold tick binds to: the
// one `dt` field at the artifact's fixed tick rate (dt = 1/tick_hz in Q32.32
// through the kernel — no float, identical bits every machine, §10). A live run
// and a replay both step at this same fixed dt, so the re-fold reproduces the
// original timing exactly. A non-positive tick rate folds to a zero dt rather than
// dividing by zero (a malformed entrypoint the loader would have refused).
@(private = "file")
replay_time_resource :: proc(tick_hz: int, allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	if tick_hz > 0 {
		fields["dt"] = fixed_div(to_fixed(1), to_fixed(i64(tick_hz)))
	} else {
		fields["dt"] = Fixed(0)
	}
	return Record_Value{type_name = "Time", fields = fields}
}
