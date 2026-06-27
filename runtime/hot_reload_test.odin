package funpack_runtime

import "core:testing"

@(private = "file")
RELOAD_ARTIFACT_A :: "funpack-artifact 19\n" +
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

@(private = "file")
RELOAD_ARTIFACT_B :: "funpack-artifact 19\n" +
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

@(private = "file")
RELOAD_ARTIFACT_B_GHOST :: "funpack-artifact 19\n" +
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

@(private = "file")
RELOAD_ARTIFACT_B_NEW_THING :: "funpack-artifact 19\n" +
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

@(private = "file")
reload_load :: proc(t: ^testing.T, artifact: string) -> (program: Program, ok: bool) {
	loaded, err := load_program(artifact, context.temp_allocator)
	if !testing.expectf(t, err == .None, "reload fixture must load, got %v", err) {
		return {}, false
	}
	return loaded, true
}

@(private = "file")
reload_time :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

@(private = "file")
reload_run :: proc(program: ^Program, n: int, allocator := context.allocator) -> World_Version {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	for _ in 0 ..< n {
		version = step_tick(program, version, empty(), reload_time(allocator), allocator)
	}
	return version
}

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

	version := step_tick(&program_b, migrated, empty(), reload_time(context.temp_allocator), context.temp_allocator)
	version = step_tick(&program_b, version, empty(), reload_time(context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, version.tables[0].rows[0].fields["pos"].(Fixed), to_fixed(7))
}

@(test)
test_hot_reload_determinism_resumes_from_migrated_state :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	first := reload_session_digests(t, RELOAD_ARTIFACT_B, 3, 4)
	second := reload_session_digests(t, RELOAD_ARTIFACT_B, 3, 4)
	if !testing.expect_value(t, len(first), 7) || !testing.expect_value(t, len(second), 7) {
		return
	}
	for digest, i in first {
		testing.expect_value(t, second[i], digest)
	}

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
	context.allocator = context.temp_allocator
	program_a, ok_a := reload_load(t, RELOAD_ARTIFACT_A)
	if !ok_a {
		return
	}
	committed := reload_run(&program_a, 3)
	before := frame_digest(committed, nil).digest

	_, _, ghost := hot_reload_swap(&program_a, committed, RELOAD_ARTIFACT_B_GHOST)
	testing.expect_value(t, ghost.ok, false)
	testing.expect_value(t, ghost.refusal.kind, Migrate_Refusal_Kind.Kernel)
	testing.expect_value(t, ghost.refusal.verdict, Schema_Diff_Error.Unknown_Source)
	testing.expect_value(t, ghost.refusal.scope, "Stats")
	testing.expect_value(t, ghost.refusal.offender, "health")

	_, _, malformed := hot_reload_swap(&program_a, committed, "funpack-artifact 8\n[meta 0]\n")
	testing.expect_value(t, malformed.ok, false)
	testing.expect_value(t, malformed.load_err, Artifact_Error.Version_Mismatch)

	testing.expect_value(t, frame_digest(committed, nil).digest, before)
	next := step_tick(&program_a, committed, empty(), reload_time(context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, next.tables[0].rows[0].fields["pos"].(Fixed), to_fixed(4))
}

@(test)
test_hot_reload_refuses_thing_set_delta :: proc(t: ^testing.T) {
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
