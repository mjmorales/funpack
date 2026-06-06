// Interpreter proof for the seeded-RNG surface (spec §04 §1, §26, §10): the
// tuple value arm, the tuple-pattern match, and the `pick(list, rng) -> (Option,
// Rng)` draw — the three connected gaps snake's `match pick(free, rng) { … }`
// needs. These tests build the node forests by hand (the snake artifact lands with
// the golden seam), so the value model and match semantics are asserted on the same
// hand-built-fixture pattern interp_test.odin uses for pong's bodies.
//
// DETERMINISM ANCHOR: every assertion ties back to the rand_test.odin GOLDEN
// indices (RAND_SEED_42_BOUNDED_10) — pick over a 10-element list seeded at 42
// selects list[7] first, so the picked element and the advanced Rng are pinned to
// the kernel's bit-exact sequence, not a hand-guessed value. A divergence in the
// generator or the boxing breaks an assertion here.
package funpack_runtime

import "core:testing"

// --- node-forest builders (file-private, mirror interp_test.odin) ----------

// rng_node_fields heap-allocates a node's scalar-token slice from the temp arena so
// a hand-built node escapes its constructing stack frame (annotation #11: a slice
// compound literal cannot escape a stack frame in Odin).
@(private = "file")
rng_node_fields :: proc(tokens: ..string) -> []string {
	out := make([]string, len(tokens), context.temp_allocator)
	copy(out, tokens)
	return out
}

// rng_node_children heap-allocates a node's child slice from the temp arena,
// mirroring rng_node_fields for the children axis.
@(private = "file")
rng_node_children :: proc(nodes: ..Node) -> []Node {
	out := make([]Node, len(nodes), context.temp_allocator)
	copy(out, nodes)
	return out
}

// rng_interp builds a minimal read-only interpreter over an empty program/version
// with the temp arena — the context a hand-built body evaluation reads against. No
// rows, no input; the RNG surface tests never touch the world.
@(private = "file")
rng_interp :: proc() -> Interp {
	program := new(Program, context.temp_allocator)
	version := new(World_Version, context.temp_allocator)
	version^ = initial_version(World{}, context.temp_allocator)
	return new_interp(program, version, nil, empty(), Record_Value{}, context.temp_allocator)
}

// rng_env makes a fresh evaluation scope over the temp arena.
@(private = "file")
rng_env :: proc() -> Env {
	return Env{names = make(map[string]Value, context.temp_allocator)}
}

// --- tuple value arm -------------------------------------------------------

// A `tuple` node evaluates to a Tuple_Value carrying its positional elements in
// source order — the in-flight aggregate a draw returns (§04 §1, `(value, next)`).
@(test)
test_eval_tuple_builds_positional_aggregate :: proc(t: ^testing.T) {
	interp := rng_interp()
	env := rng_env()

	// `(1, 2, 3)` — three int positions in order.
	a := Node{kind = .Int, fields = rng_node_fields("1")}
	b := Node{kind = .Int, fields = rng_node_fields("2")}
	c := Node{kind = .Int, fields = rng_node_fields("3")}
	tuple_node := Node{kind = .Tuple, children = rng_node_children(a, b, c)}

	result, ok := eval(&interp, &tuple_node, &env)
	testing.expect(t, ok)
	tuple, is_tuple := result.(Tuple_Value)
	testing.expect(t, is_tuple)
	testing.expect_value(t, len(tuple.elements), 3)
	testing.expect_value(t, tuple.elements[0].(i64), i64(1))
	testing.expect_value(t, tuple.elements[1].(i64), i64(2))
	testing.expect_value(t, tuple.elements[2].(i64), i64(3))
}

// A tuple compares structurally — same arity then each position in order (the §03
// Eq surface, the same length-then-elementwise rule a list uses).
@(test)
test_tuple_structural_equality :: proc(t: ^testing.T) {
	a := Tuple_Value{elements = []Value{i64(1), i64(2)}}
	b := Tuple_Value{elements = []Value{i64(1), i64(2)}}
	c := Tuple_Value{elements = []Value{i64(1), i64(3)}}
	d := Tuple_Value{elements = []Value{i64(1)}}
	testing.expect(t, values_equal(a, b))
	testing.expect(t, !values_equal(a, c))
	testing.expect(t, !values_equal(a, d)) // arity mismatch
}

// --- tuple-pattern match ---------------------------------------------------

// A tuple pattern `(Option::Some(cell), next)` over a `(Some(payload), Rng)`
// scrutinee binds BOTH the nested variant payload (`cell`) and the bare binder
// (`next`) into the arm body's scope — the recursion into per-position arm_matches
// (a variant pattern inside a tuple pattern, snake's pick-result shape).
@(test)
test_tuple_pattern_binds_nested_variant_and_bare_binder :: proc(t: ^testing.T) {
	// The arm: pat `tuple` with two child sub-arms — `variant_binds Option Some 1
	// cell` then `bare_binder - - 1 next`.
	some_sub := Node {
		kind   = .Arm,
		fields = rng_node_fields("variant_binds", "Option", "Some", "1", "cell"),
	}
	next_sub := Node {
		kind   = .Arm,
		fields = rng_node_fields("bare_binder", "-", "-", "1", "next"),
	}
	tuple_arm := Node {
		kind     = .Arm,
		fields   = rng_node_fields("tuple", "-", "-", "0"),
		children = rng_node_children(some_sub, next_sub),
	}

	// Scrutinee: (Option::Some(99), Rng{state=7}).
	payload := new(Value, context.temp_allocator)
	payload^ = i64(99)
	some := Variant_Value{enum_type = "Option", case_name = "Some", payload = payload}
	rng := Rng{state = 7}
	scrutinee := Tuple_Value{elements = []Value{some, rng}}

	scope := rng_env()
	matched := arm_matches(scrutinee, &tuple_arm, &scope)
	testing.expect(t, matched)
	// `cell` bound to the Some payload, `next` bound to the whole Rng position.
	cell, cell_present := scope.names["cell"]
	next, next_present := scope.names["next"]
	testing.expect(t, cell_present && next_present)
	testing.expect_value(t, cell.(i64), i64(99))
	testing.expect_value(t, next.(Rng).state, u64(7))
}

// The same tuple arm against an `(Option::None, Rng)` scrutinee does NOT match the
// Some-arm (the nested variant_binds requires the Some case) — so a match routes the
// None scrutinee to the OTHER arm, exactly as snake's two-arm pick match does.
@(test)
test_tuple_pattern_none_scrutinee_misses_some_arm :: proc(t: ^testing.T) {
	some_sub := Node {
		kind   = .Arm,
		fields = rng_node_fields("variant_binds", "Option", "Some", "1", "cell"),
	}
	next_sub := Node {
		kind   = .Arm,
		fields = rng_node_fields("bare_binder", "-", "-", "1", "next"),
	}
	some_arm := Node {
		kind     = .Arm,
		fields   = rng_node_fields("tuple", "-", "-", "0"),
		children = rng_node_children(some_sub, next_sub),
	}

	// Scrutinee: (Option::None, Rng) — the Some-arm's nested variant must miss.
	none := Variant_Value{enum_type = "Option", case_name = "None"}
	scrutinee := Tuple_Value{elements = []Value{none, Rng{state = 3}}}

	scope := rng_env()
	testing.expect(t, !arm_matches(scrutinee, &some_arm, &scope))
}

// A non-tuple scrutinee, or an arity mismatch, never matches a tuple pattern — the
// destructure is total and shape-checked.
@(test)
test_tuple_pattern_rejects_non_tuple_and_arity_mismatch :: proc(t: ^testing.T) {
	one_pos := Node{kind = .Arm, fields = rng_node_fields("bare_binder", "-", "-", "1", "x")}
	arm := Node {
		kind     = .Arm,
		fields   = rng_node_fields("tuple", "-", "-", "0"),
		children = rng_node_children(one_pos),
	}
	scope := rng_env()
	// A non-tuple scrutinee.
	testing.expect(t, !arm_matches(i64(5), &arm, &scope))
	// A 2-element tuple against a 1-position pattern (arity mismatch).
	two := Tuple_Value{elements = []Value{i64(1), i64(2)}}
	testing.expect(t, !arm_matches(two, &arm, &scope))
}

// --- pick draw -------------------------------------------------------------

// pick over a NON-EMPTY list returns `(Option::Some(elem), advanced_rng)`: the
// element is list[index] for the GOLDEN bounded index (seed 42 → index 7 first),
// and the Rng advances exactly one draw — the interpreter binds the kernel
// reduction to its Value element representation, boxing the hit as Option::Some.
@(test)
test_pick_some_boxes_element_and_advances :: proc(t: ^testing.T) {
	interp := rng_interp()
	env := rng_env()

	// A 10-element list and a seed-42 Rng, bound into scope.
	list := make([]Value, 10, context.temp_allocator)
	for i in 0 ..< 10 {
		list[i] = i64(100 * (i + 1)) // 100, 200, …, 1000
	}
	env.names["free"] = List_Value{elements = list}
	env.names["rng"] = rand_seed(42)

	// `pick(free, rng)` — a call over the `pick` name with two name args.
	pick_node := pick_call_node()
	result, ok := eval(&interp, &pick_node, &env)
	testing.expect(t, ok)

	tuple, is_tuple := result.(Tuple_Value)
	testing.expect(t, is_tuple)
	testing.expect_value(t, len(tuple.elements), 2)

	// Position 0: Option::Some(list[7]) — the golden first bounded index for seed 42.
	option, is_variant := tuple.elements[0].(Variant_Value)
	testing.expect(t, is_variant)
	testing.expect_value(t, option.case_name, "Some")
	testing.expect(t, option.payload != nil)
	testing.expect_value(t, option.payload^.(i64), i64(100 * (RAND_SEED_42_BOUNDED_10[0] + 1)))

	// Position 1: the advanced Rng — exactly one rand_bounded step from the seed.
	advanced, is_rng := tuple.elements[1].(Rng)
	testing.expect(t, is_rng)
	_, want := rand_bounded(rand_seed(42), 10)
	testing.expect_value(t, advanced.state, want.state)
}

// pick over an EMPTY list returns the None arm `(Option::None, advanced_rng)` yet
// STILL advances the Rng — a draw is never a silent no-op (§04 §1: the Rng is
// consumed and its successor returned even with nothing to pick).
@(test)
test_pick_empty_is_none_but_advances :: proc(t: ^testing.T) {
	interp := rng_interp()
	env := rng_env()
	env.names["free"] = List_Value{elements = make([]Value, 0, context.temp_allocator)}
	env.names["rng"] = rand_seed(42)

	pick_node := pick_call_node()
	result, ok := eval(&interp, &pick_node, &env)
	testing.expect(t, ok)
	tuple := result.(Tuple_Value)

	option := tuple.elements[0].(Variant_Value)
	testing.expect_value(t, option.case_name, "None")
	testing.expect(t, option.payload == nil) // a unit None, no boxed payload

	// The Rng advanced by exactly one rand_next even on the empty draw.
	advanced := tuple.elements[1].(Rng)
	_, want := rand_next(rand_seed(42))
	testing.expect_value(t, advanced.state, want.state)
}

// Two picks from the SAME seed reproduce the same element AND the same advanced Rng,
// and a SECOND pick threaded from the first's `next` advances again — the draw
// order is threaded forward, never silently re-seeded (§04 §1).
@(test)
test_pick_threads_forward_deterministically :: proc(t: ^testing.T) {
	interp := rng_interp()

	list := make([]Value, 10, context.temp_allocator)
	for i in 0 ..< 10 {
		list[i] = i64(i)
	}

	pick_once :: proc(interp: ^Interp, list: []Value, rng: Rng) -> (idx: i64, next: Rng) {
		env := Env{names = make(map[string]Value, context.temp_allocator)}
		env.names["free"] = List_Value{elements = list}
		env.names["rng"] = rng
		node := pick_call_node()
		result, _ := eval(interp, &node, &env)
		tuple := result.(Tuple_Value)
		picked := tuple.elements[0].(Variant_Value).payload^.(i64)
		return picked, tuple.elements[1].(Rng)
	}

	// First pick from seed 42 → golden index 0 of the bounded stream.
	idx0, next0 := pick_once(&interp, list, rand_seed(42))
	testing.expect_value(t, idx0, i64(RAND_SEED_42_BOUNDED_10[0]))
	// Second pick threaded from next0 → golden index 1 (the stream continued, not reset).
	idx1, _ := pick_once(&interp, list, next0)
	testing.expect_value(t, idx1, i64(RAND_SEED_42_BOUNDED_10[1]))

	// Re-running the identical thread from the same seed reproduces both picks.
	r0, rn := pick_once(&interp, list, rand_seed(42))
	r1, _ := pick_once(&interp, list, rn)
	testing.expect_value(t, r0, idx0)
	testing.expect_value(t, r1, idx1)
}

// pick_call_node builds a `pick(free, rng)` call node forest: a `.Call` over a
// `.Name` callee `pick` plus two `.Name` args resolving `free`/`rng` from scope —
// snake's `pick(free, rng)` shape built by hand.
@(private = "file")
pick_call_node :: proc() -> Node {
	callee := Node{kind = .Name, fields = rng_node_fields("pick")}
	free_arg := Node{kind = .Name, fields = rng_node_fields("free")}
	rng_arg := Node{kind = .Name, fields = rng_node_fields("rng")}
	return Node{kind = .Call, children = rng_node_children(callee, free_arg, rng_arg)}
}
