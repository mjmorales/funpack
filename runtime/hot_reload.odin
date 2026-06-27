package funpack_runtime

Reload_Result :: struct {
	ok:       bool,
	load_err: Artifact_Error,
	refusal:  Migrate_Refusal,
}

hot_reload_swap :: proc(
	old_program: ^Program,
	committed: World_Version,
	new_artifact: string,
	allocator := context.allocator,
) -> (
	new_program: Program,
	migrated: World_Version,
	result: Reload_Result,
) {
	loaded, load_err := load_program(new_artifact, allocator)
	if load_err != .None {
		return {}, {}, Reload_Result{load_err = load_err}
	}
	old_schemas := program_schemas(old_program, allocator)
	set, compile_refusal := compile_migration(old_schemas, &loaded, allocator)
	if compile_refusal.kind != .None {
		return {}, {}, Reload_Result{refusal = compile_refusal}
	}
	carry := tile_carry_delta(old_program.tilemaps, committed.tilemaps, allocator)
	migrated_world, migrate_refusal := migrate_world_version(set, committed, &loaded, carry, allocator)
	if migrate_refusal.kind != .None {
		return {}, {}, Reload_Result{refusal = migrate_refusal}
	}
	return loaded, migrated_world, Reload_Result{ok = true}
}
