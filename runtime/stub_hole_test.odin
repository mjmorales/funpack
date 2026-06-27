package funpack_runtime

import "core:testing"

HOLE_ARTIFACT :: "funpack-artifact 19\n" +
	"[meta 2]\n" +
	"project holes\n" +
	"version L5:0.1.0\n" +
	"[things 2]\n" +
	"thing Counter false 0 1\n" +
	"field n Fixed =0\n" +
	"thing Idle false 0 1\n" +
	"field n Fixed =0\n" +
	"[behaviors 2]\n" +
	"behavior approx_step on:Counter stage:control contract:Update 0 1 1 1\n" +
	"param self Counter\n" +
	"emit Counter\n" +
	"node stub fallback 1\n" +
	"node with 1 2\n" +
	"node name self 0\n" +
	"node recfield n 1\n" +
	"node binary add 2\n" +
	"node field n 1\n" +
	"node name self 0\n" +
	"node fixed 4294967296 0\n" +
	"behavior bare_step on:Idle stage:control contract:Update 0 1 1 1\n" +
	"param self Idle\n" +
	"emit Idle\n" +
	"node stub bare 0\n" +
	"[pipeline_flattened 2]\n" +
	"step 0 stage:control behavior:approx_step\n" +
	"step 1 stage:control behavior:bare_step\n" +
	"[setup 2]\n" +
	"spawn Counter 0\n" +
	"spawn Idle 0\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Holes tick_hz:60 logical:160x120 bindings:bindings\n"

@(private = "file")
hole_time_resource :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

@(private = "file")
load_hole_program :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(HOLE_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "holed artifact must load, got %v", err) {
		return {}, false
	}
	return loaded, true
}

@(private = "file")
run_hole_ticks :: proc(program: ^Program, n: int, allocator := context.allocator) -> World_Version {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	for _ in 0 ..< n {
		context.allocator = allocator
		version = step_tick(program, version, empty(), hole_time_resource(allocator), allocator)
	}
	return version
}

@(test)
test_load_stub_body_nodes :: proc(t: ^testing.T) {
	program, ok := load_hole_program(t)
	if !ok {
		return
	}

	approx := find_behavior(program, "approx_step")
	testing.expect(t, approx != nil)
	if approx != nil {
		testing.expect_value(t, len(approx.body), 1)
		testing.expect_value(t, approx.body[0].kind, Node_Kind.Stub)
		testing.expect_value(t, len(approx.body[0].fields), 1)
		testing.expect_value(t, approx.body[0].fields[0], "fallback")
		testing.expect_value(t, len(approx.body[0].children), 1)
		testing.expect_value(t, approx.body[0].children[0].kind, Node_Kind.With)
	}

	bare := find_behavior(program, "bare_step")
	testing.expect(t, bare != nil)
	if bare != nil {
		testing.expect_value(t, len(bare.body), 1)
		testing.expect_value(t, bare.body[0].kind, Node_Kind.Stub)
		testing.expect_value(t, len(bare.body[0].fields), 1)
		testing.expect_value(t, bare.body[0].fields[0], "bare")
		testing.expect_value(t, len(bare.body[0].children), 0)
	}

	truncated := "funpack-artifact 19\n" +
		"[behaviors 1]\n" +
		"behavior approx_step on:Counter stage:control contract:Update 0 0 0 1\n" +
		"node stub fallback 1\n"
	_, trunc_err := load_program(truncated, context.temp_allocator)
	testing.expect_value(t, trunc_err, Artifact_Error.Body_Count_Mismatch)
}

@(test)
test_stub_fallback_behavior_ticks_fallback_value :: proc(t: ^testing.T) {
	program, ok := load_hole_program(t)
	if !ok {
		return
	}

	one := run_hole_ticks(&program, 1, context.temp_allocator)
	counter, c_ok := view_at(view_of_type(&one, "Counter"), 0)
	testing.expect(t, c_ok)
	n_after_one, n_ok := row_field(counter, "n")
	testing.expect(t, n_ok)
	testing.expect_value(t, n_after_one.(Fixed), to_fixed(1))

	idle, i_ok := view_at(view_of_type(&one, "Idle"), 0)
	testing.expect(t, i_ok)
	idle_n, idle_ok := row_field(idle, "n")
	testing.expect(t, idle_ok)
	testing.expect_value(t, idle_n.(Fixed), to_fixed(0))

	three := run_hole_ticks(&program, 3, context.temp_allocator)
	counter3, _ := view_at(view_of_type(&three, "Counter"), 0)
	n_after_three, _ := row_field(counter3, "n")
	testing.expect_value(t, n_after_three.(Fixed), to_fixed(3))
	idle3, _ := view_at(view_of_type(&three, "Idle"), 0)
	idle_n3, _ := row_field(idle3, "n")
	testing.expect_value(t, idle_n3.(Fixed), to_fixed(0))
}

@(test)
test_stub_holed_fold_deterministic :: proc(t: ^testing.T) {
	program, ok := load_hole_program(t)
	if !ok {
		return
	}
	first := run_hole_ticks(&program, 10, context.temp_allocator)
	second := run_hole_ticks(&program, 10, context.temp_allocator)
	testing.expect(t, world_versions_equal(first, second))

	counter, _ := view_at(view_of_type(&first, "Counter"), 0)
	n, _ := row_field(counter, "n")
	testing.expect_value(t, n.(Fixed), to_fixed(10))
}
