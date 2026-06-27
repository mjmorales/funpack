package funpack_runtime

Scripted_Segment :: struct {
	snapshot: Input,
	ticks:    int,
}

Scripted_Record_Summary :: struct {
	tick_count: int,
	has_seed:   bool,
	seed:       i64,
}

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
