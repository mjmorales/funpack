// The HEADLESS scripted-record path (§07 §4, §23 §4, §25 §60): produce a byte-stable
// replay log from a (seed, input-script) WITHOUT an interactive SDL session, so an
// autonomous agent can bootstrap the recording the attach/time-travel surface consumes
// (session_start replay_log=… → time_* → capture_test). It is the headless TWIN of the
// live recorder: the live session (session_live.odin) resolves a snapshot from devices
// each frame and record_ticks it; this builds each tick's snapshot from a SCRIPT instead
// and record_ticks the same way — the §23 §5 "any producer is interchangeable with the
// live engine" property made an agent-drivable record path.
//
// THE LOG IS A SERIALIZATION, NOT A FOLD. A replay log is exactly the determinism record:
// the artifact-identity header (build fingerprint + the recorded tick-0 root seed, §09 §5
// / §25 §60) plus the ordered per-tick resolved Input snapshots (replay_record.odin). The
// snapshots here come straight from the script — already in the action vocabulary, no
// device to resolve — so producing the log needs NO world fold and NO render. The fold
// happens once, later, when session_start/replay re-folds the log over a freshly-loaded
// artifact (replay.odin / introspect_attach.odin), which restarts from the recorded seed
// and re-feeds these snapshots. So this layer touches no SDL, allocates no world, and is
// always-compiled + headless-tested.
//
// THE SEED RIDES THE HEADER (§25 §60). A uses_rng game (program_uses_rng) needs a tick-0
// root seed — a run-time input the artifact does not carry — resolved by the SAME §25 §60
// precedence the live session uses (resolve_root_seed: an explicit override, then the
// entrypoint config seed, then the fixed engine default) and pinned in the header. That is
// what lets a re-fold re-feed the exact seed and reproduce the seeded run; a seedless game
// (pong, hunt) records has_seed=false and re-folds the pre-evaluated [Spawn] batch.
package funpack_runtime

// Scripted_Segment is one run of identical input: a resolved §23 snapshot held for
// `ticks` consecutive recorded ticks. A script is a sequence of segments, so a whole
// recording is "idle 600, then hold Steer 100, then press Fire once" expressed as three
// segments — the per-tick snapshot is built once per segment (build_input_snapshot) and
// recorded `ticks` times. ticks is expected >= 1 (the cmd-layer marshaller refuses < 1);
// a zero/negative count records nothing for that segment.
Scripted_Segment :: struct {
	snapshot: Input,
	ticks:    int,
}

// Scripted_Record_Summary reports what record_scripted committed to the log: the total
// recorded tick count (the sum of the segments' tick counts) and the resolved tick-0
// root seed that was pinned in the header (has_seed=false for a seedless game, the seed
// field then unused). The caller (the `record` tool) echoes these so the agent learns the
// length and the exact seed baked into the recording without re-reading the log.
Scripted_Record_Summary :: struct {
	tick_count: int,
	has_seed:   bool,
	seed:       i64,
}

// record_scripted assembles a complete replay log from a loaded program, the artifact
// bytes it was loaded from, an optional `--seed`-style root-seed override, and an ordered
// input-script. It resolves the run identity EXACTLY as the live session does — the build
// fingerprint over `artifact_bytes`, seeded (identity_from_program_seeded over the §25 §60
// resolved root seed) when the program draws RNG anywhere (program_uses_rng), seedless
// otherwise — opens a replay writer against that identity (which writes the header), then
// records each segment's snapshot `ticks` times in order. It returns the assembled log
// bytes (owned by the caller, allocated on `allocator`) and the summary; the caller writes
// the bytes to disk (write_replay_file). No world is folded and no render runs: the log is
// the identity header plus the scripted snapshot stream, and the re-fold is the consumer's
// job. `artifact_bytes` MUST be the exact bytes load_program parsed `program` from — the
// header's content hash is over those raw bytes, so a recording made over different bytes
// would refuse to re-fold against the matching build.
record_scripted :: proc(
	program: ^Program,
	artifact_bytes: string,
	seed_override: Maybe(i64),
	segments: []Scripted_Segment,
	allocator := context.allocator,
) -> (
	log_bytes: string,
	summary: Scripted_Record_Summary,
) {
	// Identity derivation mirrors session_live.run_live_session: the gate is uses_rng (a
	// game whose setup is seedless but whose per-tick behaviors draw is STILL a seeded
	// run), NOT program_is_seeded — recording it seedless would drop its root seed from
	// the header and a re-fold would render black (the unseeded-uses_rng defect).
	uses_rng := program_uses_rng(program)
	root_seed := resolve_root_seed(seed_override, program.entrypoint)
	identity :=
		uses_rng ? identity_from_program_seeded(program^, artifact_bytes, root_seed) : identity_from_program(program^, artifact_bytes)

	writer := open_replay_writer(identity, allocator)
	defer delete_replay_writer(&writer)

	for segment in segments {
		for _ in 0 ..< segment.ticks {
			record_tick(&writer, segment.snapshot, allocator)
		}
	}

	log_bytes = finish_replay(&writer, allocator)
	summary = Scripted_Record_Summary {
		tick_count = writer.tick_count,
		has_seed   = identity.has_seed,
		seed       = identity.seed,
	}
	return log_bytes, summary
}
