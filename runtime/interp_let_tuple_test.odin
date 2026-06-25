// Cross-tree parity proof for the v19 `let (a, b, …) = e` TUPLE-DESTRUCTURE
// (ADR 2026-06-24-let-tuple-destructure-binding; friction 17327eb6). The runtime
// is the §29 §09 execution-side consumer: it DECODES the `let_tuple` wire node
// the funpack emitter serializes (funpack/emit_body.odin emit_let) and BINDS each
// tuple element positionally, and these tests pin that the bindings the runtime
// interpreter produces are bit-identical to the bindings the funpack COMPILER
// interpreter produces (funpack/evaluate.odin bind_let_tuple_value) — the two are
// MIRRORED behavior across a process boundary, never linked code, so a binding
// wired into one interpreter but skewed in the other (the dual-interpreter parity
// trap) breaks an assertion here.
//
// DETERMINISM ANCHOR (seed 42): the worked example `let (v, r1) = rng.range(0, 10)`
// ties to the SAME seed-42 golden the kernel (rand_test.odin RAND_SEED_42_BOUNDED_10
// = [7, …]) and the funpack-compiler twin (funpack/rand_golden_test.odin) pin — a
// 10-wide range seeded at 42 yields 7, plus the advanced Rng. So the bound `v`/`r1`
// are pinned to the kernel's bit-exact draw, not a hand-guessed value.
//
// The fixtures are the EXACT wire bytes the funpack emitter writes (`node let_tuple
// BINDER_COUNT name1 … nameN 1`), parsed through the REAL decoder (parse_node_forest)
// so the decode and the interp bind are proven together — the artifact bytes are the
// only coupling to the compiler product (spec §29, §09).
package funpack_runtime

import "core:strings"
import "core:testing"

// --- the worked-example wire bytes -----------------------------------------

// LET_TUPLE_RANGE_BODY is the EXACT §2.7 node run the funpack emitter serializes
// for `let (v, r1) = rng.range(0, 10)` followed by `return v` — the contract's
// worked example. `node let_tuple 2 v r1 1` is the v19 tuple-let (BINDER_COUNT 2,
// binders v/r1 in source order, one value child); the value is the UFCS-lowered
// `rng.range(0, 10)` call (`field range` over `name rng`, args 0 and 10), which the
// runtime evals to a (Int, Rng) tuple. The body returns `v` so eval_body yields the
// first-bound element, proving the destructure landed.
@(private = "file")
LET_TUPLE_RANGE_BODY :: "node let_tuple 2 v r1 1\n" +
	"node call 3\n" +
	"node field range 1\n" +
	"node name rng 0\n" +
	"node int 0 0\n" +
	"node int 10 0\n" +
	"node return 1\n" +
	"node name v 0\n"

// let_tuple_interp builds a minimal read-only interpreter over an empty
// program/version on the temp arena — the context a hand-built body evaluation
// reads against, mirroring interp_rng_test.odin's rng_interp.
@(private = "file")
let_tuple_interp :: proc() -> Interp {
	program := new(Program, context.temp_allocator)
	version := new(World_Version, context.temp_allocator)
	version^ = initial_version(World{}, context.temp_allocator)
	return new_interp(program, version, nil, empty(), Record_Value{}, context.temp_allocator)
}

// let_tuple_body_forest parses a body's wire text into its statement forest
// through the REAL decoder (the same path load_functions drives), so the test
// exercises the production decode of the `let_tuple` node, not a hand-built Node.
@(private = "file")
let_tuple_body_forest :: proc(text: string, body_count: int) -> []Node {
	lines := strings.split_lines(strings.trim_space(text), context.temp_allocator)
	statements, err := parse_node_forest(lines, body_count, context.temp_allocator)
	return statements if err == .None else nil
}

// --- decode: the wire format the funpack emitter writes --------------------

// The decoder reads `node let_tuple 2 v r1 1` with ZERO reader special case: the
// trailing `1` is the generic child count, and the scalar fields are
// [BINDER_COUNT, name1, …, nameN] = ["2", "v", "r1"] (every token between the kind
// tag and the count). This is the count-driven contract the file header pins.
@(test)
test_let_tuple_decodes_count_driven :: proc(t: ^testing.T) {
	line := "node let_tuple 2 v r1 1"

	count, count_ok := node_child_count(line)
	testing.expect(t, count_ok)
	testing.expect_value(t, count, 1) // the single value subtree, generic last-token read

	scalars := node_scalar_fields(line, context.temp_allocator)
	testing.expect_value(t, len(scalars), 3)
	testing.expect_value(t, scalars[0], "2") // BINDER_COUNT
	testing.expect_value(t, scalars[1], "v")
	testing.expect_value(t, scalars[2], "r1")

	kind, kind_ok := node_kind_from_tag("let_tuple")
	testing.expect(t, kind_ok)
	testing.expect_value(t, kind, Node_Kind.Let_Tuple)
}

// The full forest parse threads the binder list and the one value child into a
// Let_Tuple Node — the decoder shape the interp arm reads.
@(test)
test_let_tuple_forest_parse :: proc(t: ^testing.T) {
	body := let_tuple_body_forest(LET_TUPLE_RANGE_BODY, 2)
	testing.expect_value(t, len(body), 2) // the let_tuple statement + the return

	let_tuple := body[0]
	testing.expect_value(t, let_tuple.kind, Node_Kind.Let_Tuple)
	testing.expect_value(t, len(let_tuple.fields), 3) // [2, v, r1]
	testing.expect_value(t, let_tuple.fields[1], "v")
	testing.expect_value(t, let_tuple.fields[2], "r1")
	testing.expect_value(t, len(let_tuple.children), 1) // the one value subtree
	testing.expect_value(t, let_tuple.children[0].kind, Node_Kind.Call)
}

// --- the cross-tree binding parity (the load-bearing test) -----------------

// The worked example bound through the RUNTIME interpreter, seed 42: `v` binds to
// element 0 (the Int 7 — the RAND_SEED_42_BOUNDED_10[0] golden) and `r1` binds to
// element 1 (the advanced Rng), POSITIONALLY. This is the SAME positional contract
// funpack/evaluate.odin bind_let_tuple_value defines over the SAME seed-42 draw, so
// asserting against the kernel golden (rand_range) pins runtime↔compiler parity.
@(test)
test_let_tuple_binds_positionally_seed_42 :: proc(t: ^testing.T) {
	interp := let_tuple_interp()
	env := Env {
		names = make(map[string]Value, context.temp_allocator),
	}
	env.names["rng"] = rand_seed(42)

	body := let_tuple_body_forest(LET_TUPLE_RANGE_BODY, 2)
	testing.expect_value(t, len(body), 2)

	// eval_body folds the let_tuple (binding v/r1) then returns `v` — the returned
	// value IS the first-bound element, proving the destructure threaded into the env.
	returned, ok := eval_body(&interp, body, &env)
	testing.expect(t, ok)
	testing.expect_value(t, returned.(i64), i64(7)) // element 0 → v, the seed-42 golden

	// The env now carries both binders. Element 0 → v (Int 7), element 1 → r1
	// (the advanced Rng), matching the kernel draw bit-for-bit (the funpack twin's
	// pin). A skew in either position is the parity break this test guards.
	v_bound, v_present := env.names["v"]
	r1_bound, r1_present := env.names["r1"]
	testing.expect(t, v_present && r1_present)

	want_v, want_next := rand_range(rand_seed(42), 0, 10)
	testing.expect_value(t, v_bound.(i64), want_v) // 7
	testing.expect_value(t, v_bound.(i64), i64(7))
	testing.expect_value(t, r1_bound.(Rng).state, want_next.state) // the advanced Rng
}

// bind_let_tuple_value is the runtime twin of evaluate.odin bind_let_tuple_value:
// a matching-arity tuple binds each element positionally; a non-tuple or an
// arity skew FAILS CLOSED (ok=false, names left unbound), never traps — the SAME
// fail-closed contract the compiler twin holds. Driven directly so both the happy
// path and the two failure shapes are pinned at the binding seam.
@(test)
test_bind_let_tuple_value_arity_and_fail_closed :: proc(t: ^testing.T) {
	// Happy path: a 2-tuple binds to 2 names positionally.
	{
		env := Env{names = make(map[string]Value, context.temp_allocator)}
		tuple := Tuple_Value {
			elements = []Value{i64(7), rand_seed(42)},
		}
		ok := bind_let_tuple_value(&env, []string{"v", "r1"}, tuple)
		testing.expect(t, ok)
		testing.expect_value(t, env.names["v"].(i64), i64(7))
		testing.expect_value(t, env.names["r1"].(Rng).state, rand_seed(42).state)
	}

	// Arity skew: a 2-tuple against 3 names fails closed, binding nothing.
	{
		env := Env{names = make(map[string]Value, context.temp_allocator)}
		tuple := Tuple_Value {
			elements = []Value{i64(1), i64(2)},
		}
		ok := bind_let_tuple_value(&env, []string{"a", "b", "c"}, tuple)
		testing.expect(t, !ok)
		_, a_present := env.names["a"]
		testing.expect(t, !a_present) // left unbound — never a partial bind
	}

	// Non-tuple RHS: a bare scalar against tuple binders fails closed (the
	// typecheck-rejected program reaching eval — defended, never trapped).
	{
		env := Env{names = make(map[string]Value, context.temp_allocator)}
		ok := bind_let_tuple_value(&env, []string{"a", "b"}, i64(99))
		testing.expect(t, !ok)
		_, a_present := env.names["a"]
		testing.expect(t, !a_present)
	}
}

// A tuple-let INSIDE a guard block (if_return's v14 `block` outcome) binds into
// the block-local scope — the SECOND binding site (eval_guard_block). Without its
// own .Let_Tuple arm a guard-block tuple-let silently would not bind, so this pins
// both interp sites are wired. The block destructures, then returns the first
// binder; the guard fires (cond literal true), so the body returns 7.
@(test)
test_let_tuple_binds_inside_guard_block :: proc(t: ^testing.T) {
	// `if true { let (v, r1) = rng.range(0, 10) return v }` — the guard's outcome
	// is a `block` (v14) carrying the tuple-let + a return, exercising
	// eval_guard_block's .Let_Tuple arm. A trailing `return v` after the guard is
	// the body's fall-through (never reached when the guard fires).
	guard_body :: "node if_return 2\n" +
		"node name true_lit 0\n" +
		"node block 2\n" +
		"node let_tuple 2 v r1 1\n" +
		"node call 3\n" +
		"node field range 1\n" +
		"node name rng 0\n" +
		"node int 0 0\n" +
		"node int 10 0\n" +
		"node return 1\n" +
		"node name v 0\n" +
		"node return 1\n" +
		"node int 0 0\n"

	interp := let_tuple_interp()
	env := Env {
		names = make(map[string]Value, context.temp_allocator),
	}
	env.names["rng"] = rand_seed(42)
	env.names["true_lit"] = true // bind the guard condition to true so the block runs

	body := let_tuple_body_forest(guard_body, 2)
	testing.expect_value(t, len(body), 2)

	returned, ok := eval_body(&interp, body, &env)
	testing.expect(t, ok)
	testing.expect_value(t, returned.(i64), i64(7)) // the block-local v, seed-42 golden

	// The block-local binders never leak into the enclosing body env (§02 block
	// scoping) — v/r1 are scoped to the guard block.
	_, v_leaked := env.names["v"]
	testing.expect(t, !v_leaked)
}
