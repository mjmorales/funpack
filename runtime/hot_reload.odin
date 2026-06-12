// Hot-reload at the tick boundary (spec §09 §3): a dev-time, gated ATOMIC swap
// of a recompiled artifact between tick N and N+1. The tick boundary is the
// clean seam §09 names — the per-tick scratch is empty and only the committed
// COW blackboards are live — so the swap is "replace the code/pipeline tables
// between ticks": the caller folds tick N to a committed version, calls
// hot_reload_swap, and folds tick N+1 over the returned program + migrated
// world. Behaviors RE-RESOLVE against the new artifact's tables by name (the
// tick fold looks every pipeline step's behavior up per tick, and a behavior
// is a stateless transition — its state lives in the blackboards), so a
// changed body takes effect on the first post-swap tick.
//
// World state migrates through the SAME kernel + executor the §24 Restore uses
// (schema_diff.odin / schema_migrate.odin — "one mechanism shared with
// persistence", §09 §4): the running program's schemas are the OLD side, the
// recompiled artifact's the NEW, stable Ids preserved.
//
// RELOAD FAILURES ARE VALUES (§09 §3 "any fail ⇒ keep last-good code
// running"): a refused load or migration returns its named verdict in
// Reload_Result and produces NO program and NO world — the caller keeps the
// old artifact running, never a partial swap. The §09 §3 gate chain
// (typecheck · AX6 · contracts · effect closure · confinement · schema-diff)
// is COMPILER-owned up to its last link: `funpack` recompiles pure and re-runs
// the checked gates, so what reaches this runtime is a checked artifact; the
// runtime-side gates are the exact-match load (parse refusals, the version
// gate) and the schema-diff — the one gate that needs the LIVE world's
// schemas.
//
// Hot-reload is incompatible with lockstep replay BY CONSTRUCTION (§09 §3 —
// the code changed mid-sim, so it never ships in a session): no replay log
// records a reload, and the determinism obligation is that the fold RESUMES
// deterministically from the migrated state (the post-reload digests are a
// pure function of world + new artifact — hot_reload_test pins this).
package funpack_runtime

// Reload_Result is the reload verdict as a value: ok, or exactly one of the
// two runtime-side gate refusals — a load refusal (the recompiled artifact did
// not parse/version-match) or a migration refusal (the schema-diff kernel or
// its executor named a verdict). The §09 §3 fix-criteria diagnostic is the
// named verdict itself.
Reload_Result :: struct {
	ok:       bool,
	load_err: Artifact_Error, // .None unless the new artifact refused to load
	refusal:  Migrate_Refusal, // kind .None unless the schema migration refused
}

// hot_reload_swap runs the runtime-side reload gates over a recompiled
// artifact and, when every gate passes, returns the loaded program plus the
// committed world migrated to its schemas — the pair the caller swaps in
// atomically at the next tick boundary. On ANY refusal it returns zero values
// and the verdict: the caller keeps the old program and the old committed
// version untouched (the §09 §3 non-destructive failure; nothing here mutates
// its inputs). The caller owns WHEN to call it — between ticks, after the
// prior tick's commit — and what it does with a §24 Persist_Carrier it may be
// threading (this seam reads code + committed state only).
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
	// The old side of the diff is the RUNNING program's schemas — the same
	// projection a v5 snapshot records, so restore and reload diff identically.
	old_schemas := program_schemas(old_program, allocator)
	set, compile_refusal := compile_migration(old_schemas, &loaded, allocator)
	if compile_refusal.kind != .None {
		return {}, {}, Reload_Result{refusal = compile_refusal}
	}
	// The OLD bake is the RUNNING program's decoded tilemaps — diff the live
	// committed layers against it (exactly the cells SetTile rewrote) to source
	// the carry delta, then migrate re-bases it onto the new artifact's bake
	// (§09 §4 / §18 §4: dynamic tile state carries across reload). Reload sources
	// the delta from LIVE memory; the §24 restore reconstructs the same delta
	// from snapshot bytes — both feed the one migrate apply.
	carry := tile_carry_delta(old_program.tilemaps, committed.tilemaps, allocator)
	migrated_world, migrate_refusal := migrate_world_version(set, committed, &loaded, carry, allocator)
	if migrate_refusal.kind != .None {
		return {}, {}, Reload_Result{refusal = migrate_refusal}
	}
	return loaded, migrated_world, Reload_Result{ok = true}
}
