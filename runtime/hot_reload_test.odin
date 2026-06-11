// Hot-reload-at-the-tick-boundary acceptance (spec §09 §3, §09 §4): a
// recompiled artifact swaps between ticks — the world migrates through the
// SAME schema-diff kernel the §24 Restore uses, stable Ids are preserved,
// behaviors re-resolve against the new artifact's tables, and determinism
// resumes from the migrated state (the post-reload fold's digests are pinned
// by a double run). Reload failures are values: a refused migration or a
// malformed artifact leaves the old artifact running, never a partial swap.
//
// The fixture pair mirrors schema_migrate_test's restore pair — the SAME
// additive+rename+retype+type-rename schema delta — plus the one delta a
// reload adds over a restore: build B's `advance` body CHANGES (it advances
// pos by 2.0 where A advanced by 1.0), so the post-swap fold proves the
// behavior re-resolved to the NEW body, not a stale dispatch entry.
//
// Hot-reload never ships in a session (§09 §3 — incompatible with lockstep
// replay by construction), so there is no replay-log golden across the swap;
// the determinism obligation is fold-resumption, pinned here digest-for-digest.
package funpack_runtime

import "core:testing"

// RELOAD_ARTIFACT_A is the running build: identical to the restore fixture's
// build A (Stats{hp,mana}, Coord{v}, the Hero, advance-by-1.0).
@(private = "file")
RELOAD_ARTIFACT_A :: "funpack-artifact 13\n" +
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

// RELOAD_ARTIFACT_B is the recompiled build: the restore fixture's schema
// delta (hp→health rename, mana Int→Option[Int] retype via lift_mana, armor
// and streak additive defaults, Coord→Spot type rename) PLUS a changed
// `advance` body — `node fixed 8589934592` is 2.0 in Q32.32, so a post-swap
// tick moves pos by 2.0 (the re-resolution probe).
@(private = "file")
RELOAD_ARTIFACT_B :: "funpack-artifact 13\n" +
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
	"node fixed 8589934592 0\n" +
	"[pipeline_flattened 1]\n" +
	"step 0 stage:control behavior:advance\n" +
	"[setup 1]\n" +
	"spawn Hero 0\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Mig tick_hz:60 logical:160x120 bindings:bindings\n"

// RELOAD_ARTIFACT_B_GHOST is B with a false rename claim (`migrate ghost -`) —
// the kernel's Unknown_Source refusal, which must leave the old build running.
@(private = "file")
RELOAD_ARTIFACT_B_GHOST :: "funpack-artifact 13\n" +
	"[meta 2]\n" +
	"project mig\n" +
	"version L5:0.1.0\n" +
	"[data 2]\n" +
	"data Stats 2 false\n" +
	"field health Int -\n" +
	"migrate ghost -\n" +
	"field mana Int -\n" +
	"data Coord 1 false\n" +
	"field v Int -\n" +
	"[things 1]\n" +
	"thing Hero false 0 4\n" +
	"field pos Fixed =0\n" +
	"field stats Stats -\n" +
	"field home Coord -\n" +
	"field score Int -\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Mig tick_hz:60 logical:160x120 bindings:bindings\n"

// RELOAD_ARTIFACT_B_NEW_THING is B's schema with an ADDED thing declaration —
// a decl-SET delta §09 §4's field table does not settle, so the shared
// executor refuses it fail-closed (Thing_Set_Delta) instead of inventing
// spawn-on-reload semantics.
@(private = "file")
RELOAD_ARTIFACT_B_NEW_THING :: "funpack-artifact 13\n" +
	"[meta 2]\n" +
	"project mig\n" +
	"version L5:0.1.0\n" +
	"[data 2]\n" +
	"data Stats 2 false\n" +
	"field hp Int -\n" +
	"field mana Int -\n" +
	"data Coord 1 false\n" +
	"field v Int -\n" +
	"[things 2]\n" +
	"thing Hero false 0 4\n" +
	"field pos Fixed =0\n" +
	"field stats Stats -\n" +
	"field home Coord -\n" +
	"field score Int -\n" +
	"thing Ghost false 0 0\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Mig tick_hz:60 logical:160x120 bindings:bindings\n"

// reload_load loads a fixture, failing the test on refusal.
@(private = "file")
reload_load :: proc(t: ^testing.T, artifact: string) -> (program: Program, ok: bool) {
	loaded, err := load_program(artifact, context.temp_allocator)
	if !testing.expectf(t, err == .None, "reload fixture must load, got %v", err) {
		return {}, false
	}
	return loaded, true
}

// reload_time is the fixed 60hz Time record the fixture folds consume.
@(private = "file")
reload_time :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

// reload_run runs setup then n no-input ticks under a program.
@(private = "file")
reload_run :: proc(program: ^Program, n: int, allocator := context.allocator) -> World_Version {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	for _ in 0 ..< n {
		version = step_tick(program, version, empty(), reload_time(allocator), allocator)
	}
	return version
}

// reload_session_digests drives the full reload script — n_before ticks under
// A, the boundary swap to `new_artifact`, n_after ticks under the swapped
// program — and captures every committed tick's digest. The determinism pin
// runs it twice and compares digest-for-digest.
@(private = "file")
reload_session_digests :: proc(
	t: ^testing.T,
	new_artifact: string,
	n_before: int,
	n_after: int,
	allocator := context.allocator,
) -> []u64 {
	program, ok := reload_load(t, RELOAD_ARTIFACT_A)
	if !ok {
		return nil
	}
	digests := make([dynamic]u64, 0, n_before + n_after, allocator)
	world := new_world(program, allocator)
	version := run_startup(&program, initial_version(world, allocator), allocator)
	for _ in 0 ..< n_before {
		version = step_tick(&program, version, empty(), reload_time(allocator), allocator)
		append(&digests, frame_digest(version, nil).digest)
	}
	new_program, migrated, result := hot_reload_swap(&program, version, new_artifact, allocator)
	if !testing.expect(t, result.ok) {
		return nil
	}
	program = new_program
	version = migrated
	for _ in 0 ..< n_after {
		version = step_tick(&program, version, empty(), reload_time(allocator), allocator)
		append(&digests, frame_digest(version, nil).digest)
	}
	return digests[:]
}

@(test)
test_hot_reload_swaps_world_and_behaviors_at_boundary :: proc(t: ^testing.T) {
	// AC (the §09 §3 swap): three ticks under A (pos = 3.0), the boundary
	// swap, two ticks under B — the world migrated through the kernel (the
	// restore fixture's full delta), the stable Id survived, and the post-swap
	// folds advance by B's CHANGED body (2.0/tick): behaviors re-resolved
	// against the new artifact's tables, not a stale dispatch entry.
	context.allocator = context.temp_allocator
	program_a, ok_a := reload_load(t, RELOAD_ARTIFACT_A)
	if !ok_a {
		return
	}
	committed := reload_run(&program_a, 3)
	saved_id := committed.tables[0].rows[0].id

	program_b, migrated, result := hot_reload_swap(&program_a, committed, RELOAD_ARTIFACT_B)
	if !testing.expect(t, result.ok) {
		return
	}
	testing.expect_value(t, result.load_err, Artifact_Error.None)
	testing.expect_value(t, result.refusal.kind, Migrate_Refusal_Kind.None)

	// The migrated world: Id preserved, the §09 §4 delta folded (rename,
	// retype-through-conversion, additive defaults, the renamed data type).
	hero := migrated.tables[0].rows[0]
	testing.expect_value(t, hero.id, saved_id)
	testing.expect_value(t, hero.fields["pos"].(Fixed), to_fixed(3))
	testing.expect_value(t, hero.fields["streak"].(i64), i64(3))
	stats := hero.fields["stats"].(Record_Value)
	testing.expect_value(t, stats.fields["health"].(i64), i64(10))
	testing.expect_value(t, stats.fields["armor"].(i64), i64(7))
	mana := stats.fields["mana"].(Variant_Value)
	testing.expect_value(t, mana.case_name, "Some")
	if testing.expect(t, mana.payload != nil) {
		testing.expect_value(t, mana.payload^.(i64), i64(4))
	}
	testing.expect_value(t, hero.fields["home"].(Record_Value).type_name, "Spot")

	// Two post-swap ticks fold B's body: pos advances 3.0 → 5.0 → 7.0.
	version := step_tick(&program_b, migrated, empty(), reload_time(context.temp_allocator), context.temp_allocator)
	version = step_tick(&program_b, version, empty(), reload_time(context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, version.tables[0].rows[0].fields["pos"].(Fixed), to_fixed(7))
}

@(test)
test_hot_reload_determinism_resumes_from_migrated_state :: proc(t: ^testing.T) {
	// AC (the digest pins the post-reload fold): the whole script — fold under
	// A, swap, fold under B — run twice produces bit-identical per-tick
	// digests, so determinism RESUMES from the migrated state (the migration
	// is a pure function of world + new artifact). A no-reload control run
	// diverges at the first post-swap tick, so the pin is not vacuous.
	context.allocator = context.temp_allocator
	first := reload_session_digests(t, RELOAD_ARTIFACT_B, 3, 4)
	second := reload_session_digests(t, RELOAD_ARTIFACT_B, 3, 4)
	if !testing.expect_value(t, len(first), 7) || !testing.expect_value(t, len(second), 7) {
		return
	}
	for digest, i in first {
		testing.expect_value(t, second[i], digest)
	}

	// The control: the same 7 ticks under A alone. The pre-swap digests agree
	// tick-for-tick; the first post-swap digest differs (B's world carries the
	// migrated schema and B's body moved pos differently) — the swap is
	// observable in the digest stream.
	program_a, ok_a := reload_load(t, RELOAD_ARTIFACT_A)
	if !ok_a {
		return
	}
	world := new_world(program_a)
	version := run_startup(&program_a, initial_version(world))
	control := make([dynamic]u64, 0, 7)
	for _ in 0 ..< 7 {
		version = step_tick(&program_a, version, empty(), reload_time(context.temp_allocator), context.temp_allocator)
		append(&control, frame_digest(version, nil).digest)
	}
	for i in 0 ..< 3 {
		testing.expect_value(t, first[i], control[i])
	}
	testing.expect(t, first[3] != control[3])
}

@(test)
test_hot_reload_refusal_keeps_old_artifact_running :: proc(t: ^testing.T) {
	// AC (reload failures are values, §09 §3 non-destructive): a refused
	// migration (Unknown_Source) and a malformed recompile each return their
	// named verdict and NOTHING else — the old program and the old committed
	// version are untouched, and the next tick folds under A exactly as if the
	// reload had never been attempted. Never a partial swap.
	context.allocator = context.temp_allocator
	program_a, ok_a := reload_load(t, RELOAD_ARTIFACT_A)
	if !ok_a {
		return
	}
	committed := reload_run(&program_a, 3)
	before := frame_digest(committed, nil).digest

	// The kernel refusal: a false rename claim about the running schema.
	_, _, ghost := hot_reload_swap(&program_a, committed, RELOAD_ARTIFACT_B_GHOST)
	testing.expect_value(t, ghost.ok, false)
	testing.expect_value(t, ghost.refusal.kind, Migrate_Refusal_Kind.Kernel)
	testing.expect_value(t, ghost.refusal.verdict, Schema_Diff_Error.Unknown_Source)
	testing.expect_value(t, ghost.refusal.scope, "Stats")
	testing.expect_value(t, ghost.refusal.offender, "health")

	// The load refusal: a recompile stamped with a schema this build was not
	// built for (the stale prior version), refused before any payload.
	_, _, malformed := hot_reload_swap(&program_a, committed, "funpack-artifact 8\n[meta 0]\n")
	testing.expect_value(t, malformed.ok, false)
	testing.expect_value(t, malformed.load_err, Artifact_Error.Version_Mismatch)

	// The old artifact keeps running: the committed world is byte-untouched
	// and the next tick folds under A's body (pos 3.0 → 4.0).
	testing.expect_value(t, frame_digest(committed, nil).digest, before)
	next := step_tick(&program_a, committed, empty(), reload_time(context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, next.tables[0].rows[0].fields["pos"].(Fixed), to_fixed(4))
}

@(test)
test_hot_reload_refuses_thing_set_delta :: proc(t: ^testing.T) {
	// AC (the settled-spec boundary fails closed): a recompile that ADDS a
	// thing declaration is a decl-set delta §09 §4's field table does not
	// settle — the shared executor refuses it (Thing_Set_Delta) and the old
	// build keeps running, rather than inventing spawn-on-reload semantics.
	context.allocator = context.temp_allocator
	program_a, ok_a := reload_load(t, RELOAD_ARTIFACT_A)
	if !ok_a {
		return
	}
	committed := reload_run(&program_a, 1)
	_, _, result := hot_reload_swap(&program_a, committed, RELOAD_ARTIFACT_B_NEW_THING)
	testing.expect_value(t, result.ok, false)
	testing.expect_value(t, result.refusal.kind, Migrate_Refusal_Kind.Thing_Set_Delta)
}
