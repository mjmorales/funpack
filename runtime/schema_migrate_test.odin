// Restore-across-a-schema-change acceptance (spec §24 §1, §09 §4): a slot
// saved under build A restores under build B by diffing the snapshot's
// recorded schemas against B's decls (the v5 codec carry) and folding the
// schema-diff kernel's plan over the rows — the SAME kernel hot-reload uses
// (schema_diff.odin, the runtime's own copy; schema_migrate.odin, the
// executor). The fixtures are HAND-WRITTEN v8 artifact text (the
// artifact-before-artifact discipline, stub_hole_test's pattern), so the
// migrate metadata flows the producer-real path: artifact bytes → loader
// tables → kernel plan → migrated world.
//
// The golden delta is the full §09 §4 verdict-table walk in one pair:
//   - ADDITIVE  : thing-level `streak: Int = 3` and data-level `armor: Int = 7`
//   - RENAME    : Stats.hp → Stats.health (`migrate hp -`)
//   - RETYPE    : Stats.mana Int → Option[Int] through `migrate - lift_mana`
//                 (the §05 §6 conversion fn, an ordinary [functions] record)
//   - TYPE RENAME: data Coord → Spot (`migrate Coord -` decl-level), with the
//                 Hero's `home` column re-typed by canonicalized spelling
//   - CARRY     : pos/score/stats/home carry by name, Ids preserved
//
// Refusals are values, never partial worlds: an Unknown_Source directive and a
// silent retype both surface as the Restore failure Result (ok=false at the
// store level; Restored{Err} + no swap at the §24 command level).
package funpack_runtime

import "core:testing"

// MIG_ARTIFACT_A is build A: Stats{hp,mana} + Coord{v}, a Hero carrying both
// plus a Fixed pos and an Int score, and one control behavior advancing pos by
// 1.0 each tick (so the saved world is not the startup world).
@(private = "file")
MIG_ARTIFACT_A :: "funpack-artifact 15\n" +
	"[meta 2]\n" +
	"project mig\n" +
	"version L5:0.1.0\n" +
	"[data 2]\n" +
	"data Stats 2 false\n" +
	"field hp Int -\n" +
	"field mana Int -\n" +
	"data Coord 1 false\n" +
	"field v Int -\n" +
	"[things 1]\n" +
	"thing Hero false 0 4\n" +
	"field pos Fixed =0\n" +
	"field stats Stats =Stats(hp=10,mana=4)\n" +
	"field home Coord =Coord(v=5)\n" +
	"field score Int =0\n" +
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
	"entrypoint main pipeline:Mig tick_hz:60 logical:160x120 bindings:bindings\n"

// MIG_ARTIFACT_B is build B — A after the schema evolution: Stats renames hp →
// health, retypes mana Int → Option[Int] through lift_mana, and adds the
// defaulted armor; Coord is renamed to Spot at the decl level; Hero re-types
// `home` by the renamed spelling and adds the defaulted streak. The behavior
// and pipeline are unchanged — this pair isolates the SCHEMA delta.
@(private = "file")
MIG_ARTIFACT_B :: "funpack-artifact 15\n" +
	"[meta 2]\n" +
	"project mig\n" +
	"version L5:0.1.0\n" +
	"[data 2]\n" +
	"data Stats 3 false\n" +
	"field health Int -\n" +
	"migrate hp -\n" +
	"field mana Option[Int] -\n" +
	"migrate - lift_mana\n" +
	"field armor Int =7\n" +
	"data Spot 1 false\n" +
	"migrate Coord -\n" +
	"field v Int -\n" +
	"[things 1]\n" +
	"thing Hero false 0 5\n" +
	"field pos Fixed =0\n" +
	"field stats Stats -\n" +
	"field home Spot -\n" +
	"field score Int -\n" +
	"field streak Int =3\n" +
	"[functions 1]\n" +
	"function lift_mana fn 1 return:Option[Int] 1 span:mig:1\n" +
	"param n Int\n" +
	"node return 1\n" +
	"node variant Option Some true 1\n" +
	"node name n 0\n" +
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
	"entrypoint main pipeline:Mig tick_hz:60 logical:160x120 bindings:bindings\n"

// MIG_ARTIFACT_B_GHOST is B with a FALSE rename claim: `migrate ghost -` names
// a prior key A's Stats never had — the kernel's Unknown_Source refusal, which
// must surface as the Restore failure Result, never a partial world.
@(private = "file")
MIG_ARTIFACT_B_GHOST :: "funpack-artifact 15\n" +
	"[meta 2]\n" +
	"project mig\n" +
	"version L5:0.1.0\n" +
	"[data 1]\n" +
	"data Stats 2 false\n" +
	"field health Int -\n" +
	"migrate ghost -\n" +
	"field mana Int -\n" +
	"[things 1]\n" +
	"thing Hero false 0 1\n" +
	"field stats Stats -\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Mig tick_hz:60 logical:160x120 bindings:bindings\n"

// MIG_ARTIFACT_B_SILENT_RETYPE is B with mana retyped WITHOUT a directive —
// the §09 §4 "change field type: breaking" verdict (Retype_Without_Migrate).
@(private = "file")
MIG_ARTIFACT_B_SILENT_RETYPE :: "funpack-artifact 15\n" +
	"[meta 2]\n" +
	"project mig\n" +
	"version L5:0.1.0\n" +
	"[data 1]\n" +
	"data Stats 2 false\n" +
	"field hp Int -\n" +
	"field mana Option[Int] -\n" +
	"[things 1]\n" +
	"thing Hero false 0 1\n" +
	"field stats Stats -\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Mig tick_hz:60 logical:160x120 bindings:bindings\n"

// mig_load loads one of the hand-written fixtures, failing the test on refusal.
@(private = "file")
mig_load :: proc(t: ^testing.T, artifact: string) -> (program: Program, ok: bool) {
	loaded, err := load_program(artifact, context.temp_allocator)
	if !testing.expectf(t, err == .None, "migration fixture must load, got %v", err) {
		return {}, false
	}
	return loaded, true
}

// mig_time is the fixed 60hz Time record the fixture folds consume.
@(private = "file")
mig_time :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

// mig_run runs setup then n no-input ticks — the world a quicksave captures.
@(private = "file")
mig_run :: proc(program: ^Program, n: int, allocator := context.allocator) -> World_Version {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	for _ in 0 ..< n {
		version = step_tick(program, version, empty(), mig_time(allocator), allocator)
	}
	return version
}

// --- The v8 loader carry: migrate sub-records land in the decl tables -------

@(test)
test_load_migrate_subrecords_into_decl_tables :: proc(t: ^testing.T) {
	// AC (loader): the three field-level §05 §6 forms and the decl-level type
	// rename all land in the loaded tables — Field_Decl carries the from/with
	// halves, Data_Decl the prior type name — exactly as the kernel reads them.
	context.allocator = context.temp_allocator
	program, ok := mig_load(t, MIG_ARTIFACT_B)
	if !ok {
		return
	}

	stats := program.data[0]
	testing.expect_value(t, stats.name, "Stats")
	testing.expect_value(t, stats.has_prior, false)
	testing.expect_value(t, len(stats.fields), 3)
	// health: the rename form — FROM only.
	testing.expect_value(t, stats.fields[0].name, "health")
	testing.expect_value(t, stats.fields[0].has_from, true)
	testing.expect_value(t, stats.fields[0].migrate_from, "hp")
	testing.expect_value(t, stats.fields[0].has_with, false)
	// mana: the retype form — WITH only.
	testing.expect_value(t, stats.fields[1].name, "mana")
	testing.expect_value(t, stats.fields[1].has_from, false)
	testing.expect_value(t, stats.fields[1].has_with, true)
	testing.expect_value(t, stats.fields[1].migrate_with, "lift_mana")
	// armor: directive-free, default-carrying.
	testing.expect_value(t, stats.fields[2].name, "armor")
	testing.expect_value(t, stats.fields[2].has_from, false)
	testing.expect_value(t, stats.fields[2].has_with, false)
	testing.expect_value(t, stats.fields[2].has_default, true)

	// Spot: the decl-level type rename — prior_name Coord, fields clean.
	spot := program.data[1]
	testing.expect_value(t, spot.name, "Spot")
	testing.expect_value(t, spot.has_prior, true)
	testing.expect_value(t, spot.prior_name, "Coord")
	testing.expect_value(t, spot.fields[0].has_from, false)
}

@(test)
test_load_malformed_migrate_refused :: proc(t: ^testing.T) {
	// AC (loader refusals, fail-closed): a both-`-` migrate line, a decl-level
	// WITH half, a migrate with no field to attach to, and a migrate inside
	// [things] (the data schema is the only evolution channel) are each a
	// Bad_Field refusal — never a leniently-parsed partial program.
	context.allocator = context.temp_allocator

	both_absent := "funpack-artifact 15\n[data 1]\ndata D 1 false\nfield a Int -\nmigrate - -\n"
	_, both_err := load_program(both_absent, context.temp_allocator)
	testing.expect_value(t, both_err, Artifact_Error.Bad_Field)

	decl_with := "funpack-artifact 15\n[data 1]\ndata D 1 false\nmigrate Old lift\nfield a Int -\n"
	_, decl_err := load_program(decl_with, context.temp_allocator)
	testing.expect_value(t, decl_err, Artifact_Error.Bad_Field)

	things_migrate := "funpack-artifact 15\n[things 1]\nthing T false 0 1\nfield a Int -\nmigrate x -\n"
	_, things_err := load_program(things_migrate, context.temp_allocator)
	testing.expect_value(t, things_err, Artifact_Error.Bad_Field)
}

// --- The golden round-trip: save under A, restore under B -------------------

@(test)
test_restore_migrates_across_additive_rename_retype :: proc(t: ^testing.T) {
	// AC (the §24/§09 §4 golden): a slot saved under A restores under B with
	// every verdict-table arm exercised — renamed/retyped/additive data fields,
	// the renamed data TYPE, the additive thing field — and the carried values
	// bit-exact, the Id preserved, never a partial world.
	context.allocator = context.temp_allocator
	program_a, ok_a := mig_load(t, MIG_ARTIFACT_A)
	if !ok_a {
		return
	}

	// Three ticks under A: pos = 3.0, everything else at its spawned value.
	saved_world := mig_run(&program_a, 3)
	saved_id := saved_world.tables[0].rows[0].id

	store := new_in_memory_store()
	testing.expect(t, apply_save(&store, &program_a, saved_world, "quicksave"))

	program_b, ok_b := mig_load(t, MIG_ARTIFACT_B)
	if !ok_b {
		return
	}
	restored, restore_ok := apply_restore(&store, &program_b, "quicksave")
	if !testing.expect(t, restore_ok) {
		return
	}

	// Identity preserved: same tick, same table shape, same stable Id.
	testing.expect_value(t, restored.tick, saved_world.tick)
	testing.expect_value(t, len(restored.tables), 1)
	hero := restored.tables[0].rows[0]
	testing.expect_value(t, hero.id, saved_id)

	// CARRY: pos rode the fold bit-exact (3 ticks × 1.0), score verbatim.
	testing.expect_value(t, hero.fields["pos"].(Fixed), to_fixed(3))
	testing.expect_value(t, hero.fields["score"].(i64), i64(0))

	// ADDITIVE (thing level): streak seeds its declared default.
	testing.expect_value(t, hero.fields["streak"].(i64), i64(3))

	// The Stats column reshaped through its plan: RENAME carried hp's value
	// into health, RETYPE ran mana through lift_mana (Int 4 → Option::Some(4)),
	// ADDITIVE seeded armor's default, and the dropped hp key is gone.
	stats := hero.fields["stats"].(Record_Value)
	testing.expect_value(t, stats.fields["health"].(i64), i64(10))
	testing.expect_value(t, stats.fields["armor"].(i64), i64(7))
	_, hp_lives := stats.fields["hp"]
	testing.expect_value(t, hp_lives, false)
	mana := stats.fields["mana"].(Variant_Value)
	testing.expect_value(t, mana.enum_type, "Option")
	testing.expect_value(t, mana.case_name, "Some")
	if testing.expect(t, mana.payload != nil) {
		testing.expect_value(t, mana.payload^.(i64), i64(4))
	}

	// TYPE RENAME: the home column's record re-typed Coord → Spot, value carried.
	home := hero.fields["home"].(Record_Value)
	testing.expect_value(t, home.type_name, "Spot")
	testing.expect_value(t, home.fields["v"].(i64), i64(5))

	// Determinism resumes from the migrated state: two independent post-restore
	// folds under B produce bit-identical digests (the migration is a pure
	// function of slot + program, so the restored world folds reproducibly).
	first := step_tick(&program_b, restored, empty(), mig_time(context.temp_allocator), context.temp_allocator)
	second := step_tick(&program_b, restored, empty(), mig_time(context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, frame_digest(first, nil).digest, frame_digest(second, nil).digest)
	// And the fold advanced from the CARRIED pos — the migrated world is live.
	testing.expect_value(t, first.tables[0].rows[0].fields["pos"].(Fixed), to_fixed(4))
}

@(test)
test_restore_under_same_schema_is_identity :: proc(t: ^testing.T) {
	// AC (the no-delta floor): a slot restored under the build that saved it
	// folds the all-Carry identity plan — value-identical world, identical
	// digest — so the schema carry costs the common same-build restore nothing.
	context.allocator = context.temp_allocator
	program, ok := mig_load(t, MIG_ARTIFACT_A)
	if !ok {
		return
	}
	saved_world := mig_run(&program, 2)
	store := new_in_memory_store()
	testing.expect(t, apply_save(&store, &program, saved_world, "quicksave"))

	restored, restore_ok := apply_restore(&store, &program, "quicksave")
	if !testing.expect(t, restore_ok) {
		return
	}
	testing.expect(t, world_versions_equal(saved_world, restored))
	testing.expect_value(t, frame_digest(restored, nil).digest, frame_digest(saved_world, nil).digest)
}

// --- Refusals are the Restore failure Result, never a partial world ---------

@(test)
test_restore_refuses_unknown_source_directive :: proc(t: ^testing.T) {
	// AC (kernel refusal → Restore Err): a @migrate naming a prior key the
	// snapshot's schema lacks refuses the whole restore (ok=false at the store
	// level; Restored{Err} and NO swap at the §24 command level) — the §09 §4
	// diagnostic arm, never a silently-defaulted field or a partial world.
	context.allocator = context.temp_allocator
	program_a, ok_a := mig_load(t, MIG_ARTIFACT_A)
	if !ok_a {
		return
	}
	saved_world := mig_run(&program_a, 1)
	store := new_in_memory_store()
	testing.expect(t, apply_save(&store, &program_a, saved_world, "quicksave"))

	program_ghost, ok_ghost := mig_load(t, MIG_ARTIFACT_B_GHOST)
	if !ok_ghost {
		return
	}
	_, restore_ok := apply_restore(&store, &program_ghost, "quicksave")
	testing.expect_value(t, restore_ok, false)

	// The §24 command surface: the queued outcome is the forced Err arm and the
	// effects carry no swap — the old world keeps running at the boundary.
	slot_fields := make(map[string]Value)
	slot_fields["slot"] = String_Value{text = "quicksave"}
	commands := []Record_Value{Record_Value{type_name = "Restore", fields = slot_fields}}
	effects := process_persist_commands(&store, &program_ghost, saved_world, commands)
	testing.expect_value(t, len(effects.outcomes), 1)
	testing.expect_value(t, effects.outcomes[0].signal, "Restored")
	testing.expect_value(t, effects.outcomes[0].ok, false)
	_, has_swap := effects.swap.?
	testing.expect_value(t, has_swap, false)
}

@(test)
test_restore_refuses_silent_retype :: proc(t: ^testing.T) {
	// AC (silent retype → Restore Err): a same-named field whose type changed
	// with no directive is the §09 §4 breaking verdict — the repair is
	// @migrate(with: convert), never a best-effort coercion.
	context.allocator = context.temp_allocator
	program_a, ok_a := mig_load(t, MIG_ARTIFACT_A)
	if !ok_a {
		return
	}
	saved_world := mig_run(&program_a, 1)
	store := new_in_memory_store()
	testing.expect(t, apply_save(&store, &program_a, saved_world, "quicksave"))

	program_bad, ok_bad := mig_load(t, MIG_ARTIFACT_B_SILENT_RETYPE)
	if !ok_bad {
		return
	}
	_, restore_ok := apply_restore(&store, &program_bad, "quicksave")
	testing.expect_value(t, restore_ok, false)
}
