// The §05 §2 typed-hole RUNTIME arms (the v7 `stub` carry): a loaded `stub` node
// dispatches at tick time exactly like the compiler interpreter's
// eval_stub_hole (funpack/evaluate.odin) — a `stub fallback` behavior ticks
// its approximation expression live in the step's param-bound scope (P8: the
// game stays playable under the hole), and a `stub bare` behavior FAILS
// CLOSED: the instance folds nothing that tick, a defined no-value outcome,
// never a trap. The fixture is HAND-WRITTEN artifact text per the
// artifact-before-artifact pattern (runtime owns no funpack import; the
// format doc alone is the contract) — the producer-real emission of these
// same node bytes is pinned on the funpack side (emit_stub_test.odin's
// amended-pong golden, since no committed spec example authors a pipelined
// hole — the drift example's pipeline is empty).
package funpack_runtime

import "core:testing"

// HOLE_ARTIFACT is the minimal holed program (the v7 `stub` carry, stamped at
// the current schema version): a Counter thing stepped by a
// fallback-holed behavior whose approximation is `self with { n: self.n + 1.0 }`
// (so every tick advances n by exactly 1.0 in Q32.32), and an Idle thing
// stepped by a bare typecheck-only hole (so no tick ever writes it). Both
// behaviors occupy REAL flattened control steps — the pipelined-hole surface.
HOLE_ARTIFACT :: "funpack-artifact 18\n" +
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

// hole_time_resource is the fixed 60hz Time record the holed fold consumes —
// the tick_test shape, local so this file stays self-contained.
@(private = "file")
hole_time_resource :: proc(allocator := context.allocator) -> Record_Value {
	fields := make(map[string]Value, allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

// load_hole_program loads the hand-written holed artifact, failing the test on
// any refusal — the load is total or fail-closed, never partial.
@(private = "file")
load_hole_program :: proc(t: ^testing.T) -> (program: Program, ok: bool) {
	loaded, err := load_program(HOLE_ARTIFACT, context.temp_allocator)
	if !testing.expectf(t, err == .None, "holed artifact must load, got %v", err) {
		return {}, false
	}
	return loaded, true
}

// run_hole_ticks runs setup then n no-input ticks over the holed program — the
// closed, input-fixed fold the determinism assertion repeats.
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
	// AC (loader): the v7-carried `stub` node loads as a first-class body statement —
	// the fallback hole's body is one Stub node with the `fallback` form and
	// its single approximation-expression child, the bare hole's one Stub
	// node with the `bare` form and no child.
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

	// An under-shaped fallback stub (a declared child that is absent) is a
	// fail-closed refusal, never a partial body.
	truncated := "funpack-artifact 18\n" +
		"[behaviors 1]\n" +
		"behavior approx_step on:Counter stage:control contract:Update 0 0 0 1\n" +
		"node stub fallback 1\n"
	_, trunc_err := load_program(truncated, context.temp_allocator)
	testing.expect_value(t, trunc_err, Artifact_Error.Body_Count_Mismatch)
}

@(test)
test_stub_fallback_behavior_ticks_fallback_value :: proc(t: ^testing.T) {
	// AC (the approximation runs live): a loaded fallback-holed behavior ticks
	// producing the fallback value — Counter.n advances by exactly 1.0
	// (Q32.32 bit-exact) per tick, the same value the compiler interpreter's
	// eval_stub_hole computes — while the BARE-holed behavior fails closed:
	// Idle.n never moves, the instance folds nothing, and the tick completes
	// (a defined no-value outcome, never a trap).
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

	// Three ticks accumulate the approximation: the fallback evaluates against
	// the WORKING self each tick (the param-bound scope), not a stale spawn.
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
	// AC (determinism): two independent 10-tick folds over the holed program
	// commit BIT-IDENTICAL world versions — the stub dispatch is fixed-point
	// only, so same inputs replay bit-identically (the same floor every
	// intact-body fold stands on).
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
