package funpack_runtime

import "core:fmt"

Replay_Refusal :: enum {
	None,
	Identity_Mismatch,
}

Replay_Result :: struct {
	refusal:   Replay_Refusal,
	world:     World_Version,
	diagnostic: string,
}

Run_Seed :: struct {
	has_seed: bool,
	seed:     i64,
}

NO_SEED :: Run_Seed{has_seed = false, seed = 0}

seeded_run :: proc(seed: i64) -> Run_Seed {
	return Run_Seed{has_seed = true, seed = seed}
}

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

Replay_Capture_Result :: struct {
	refusal:    Replay_Refusal,
	capture:    Frame_Capture,
	diagnostic: string,
}

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

@(private = "file")
seed_diagnostic :: proc(identity: Replay_Identity, allocator := context.allocator) -> string {
	if !identity.has_seed {
		return "seed=none"
	}
	return fmt.aprintf("seed=%d", identity.seed, allocator = allocator)
}

time_dt :: proc(tick_hz: int) -> Fixed {
	if tick_hz > 0 {
		return fixed_div(to_fixed(1), to_fixed(i64(tick_hz)))
	}
	return Fixed(0)
}

time_resource :: proc(tick_hz: int, allocator := context.allocator) -> Record_Value {
	return time_resource_at(tick_hz, 0, allocator)
}

time_resource_at :: proc(tick_hz: int, tick: int, allocator := context.allocator) -> Record_Value {
	dt := time_dt(tick_hz)
	fields := make(map[string]Value, allocator)
	fields["dt"] = dt
	fields["t"] = fixed_mul(dt, to_fixed(i64(tick)))
	return Record_Value{type_name = "Time", fields = fields}
}
