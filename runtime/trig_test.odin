// Trig-kernel proof over the copied fixed_sin polynomial (spec §10: the
// bit-identical transcendental contract). Three obligations land here: sin(0) is
// exactly Fixed(0) (the odd polynomial vanishes at zero by construction), the
// runtime fixed_sin bits equal the funpack fixed_sin bits over a pinned cardinal
// angle set (the determinism bet — pose-driven replay folds the SAME Q32.32 sin
// the funpack evaluator does), and the `sin` builtin + `tau` const evaluate
// through the interp over a hand-built node forest to those same bits. The
// expected funpack-side bits are baked CONSTANTS (runtime never imports funpack):
// they were computed once from the funpack package's own fixed_sin over the
// identical kernel-constructed angle set and pinned below with their provenance.
package funpack_runtime

import "core:testing"

// PINNED_ANGLE / PINNED_SIN are the cross-product the bit-identity floor rests
// on, captured once from a throwaway run of funpack's fixed_sin over angles built
// through the kernel from TAU_FIXED (no float on the path):
//
//   tau     = TAU_FIXED
//   tau/8   = fixed_div(tau, to_fixed(8))
//   tau/4   = fixed_div(tau, to_fixed(4))
//   3*tau/8 = fixed_mul(to_fixed(3), tau/8)
//   tau/2   = fixed_div(tau, to_fixed(2))
//   3*tau/4 = fixed_mul(to_fixed(3), tau/4)
//   tau     = TAU_FIXED (the wrap boundary advance_gait's `% tau` rides)
//   gait    = fixed_div(to_fixed(7), to_fixed(10))  (0.7, a non-cardinal gait angle)
//
// PROVENANCE: the SIN_BITS were emitted by funpack/fixed_sin over these exact
// kernel-built angles (a throwaway funpack test that printed i64(fixed_sin(a)),
// run once and removed). The angle bits are recomputed below from the SAME kernel
// the runtime ships, so the test asserts both that the angles match (the input is
// identical) and that the runtime sin bits equal the funpack sin bits (the output
// is identical). Any kernel drift breaks this — that is the audit it exists for.

// Angle bits (i64 of the Q32.32 angle), funpack-side provenance pinned in order.
PINNED_ANGLE_BITS :: [8]i64 {
	0, // 0
	3373259426, // tau/8
	6746518852, // tau/4
	10119778278, // 3*tau/8
	13493037704, // tau/2 (== PI_FIXED − 1; each rounds independently)
	20239556556, // 3*tau/4
	26986075409, // tau (TAU_FIXED, the wrap boundary)
	3006477107, // gait 7/10
}

// sin bits (i64 of fixed_sin over the matching angle), funpack-side provenance.
PINNED_SIN_BITS :: [8]i64 {
	0, // sin(0) — exact zero
	3037156255, // sin(tau/8)
	4314401403, // sin(tau/4)
	3355363922, // sin(3*tau/8)
	2250751470, // sin(tau/2)
	28504265673, // sin(3*tau/4)
	199916693143, // sin(tau)
	2766963603, // sin(gait)
}

// pinned_angles rebuilds the angle set through the runtime kernel — the SAME
// arithmetic funpack used to build the angles whose sin bits are pinned above, so
// a kernel divergence shows up as an angle mismatch before the sin mismatch.
@(private = "file")
pinned_angles :: proc() -> [8]Fixed {
	tau := TAU_FIXED
	eighth := fixed_div(tau, to_fixed(8))
	quarter := fixed_div(tau, to_fixed(4))
	half := fixed_div(tau, to_fixed(2))
	return [8]Fixed {
		Fixed(0),
		eighth,
		quarter,
		fixed_mul(to_fixed(3), eighth),
		half,
		fixed_mul(to_fixed(3), quarter),
		tau,
		fixed_div(to_fixed(7), to_fixed(10)),
	}
}

// sin(0) is exactly Fixed(0) — the odd polynomial vanishes at zero by
// construction — and every cardinal phase advance_gait's gait wraps at folds to
// the kernel's exact bits. The angles are rebuilt here, not literal, so the test
// pins the kernel-constructed phase the gait actually reads.
@(test)
test_fixed_sin_cardinals :: proc(t: ^testing.T) {
	// sin(0) is exactly zero — the determinism floor's anchor.
	testing.expect_value(t, fixed_sin(Fixed(0)), Fixed(0))

	angles := pinned_angles()
	expected_angle := PINNED_ANGLE_BITS
	// Every cardinal angle matches its funpack-side bits (the input is identical).
	for a, i in angles {
		testing.expect_value(t, i64(a), expected_angle[i])
	}
	// fixed_sin over each cardinal is total and lands on the pinned kernel bits.
	expected_sin := PINNED_SIN_BITS
	for a, i in angles {
		testing.expect_value(t, i64(fixed_sin(a)), expected_sin[i])
	}
}

// The runtime fixed_sin Q32.32 bits equal the funpack fixed_sin bits for the
// pinned cardinal-angle set — the bit-identity the determinism floor rests on
// (kernel-copy-not-link: runtime carries no funpack import, so the funpack bits
// are baked constants computed once from the funpack package).
@(test)
test_fixed_sin_matches_funpack_bits :: proc(t: ^testing.T) {
	angles := pinned_angles()
	expected := PINNED_SIN_BITS
	for a, i in angles {
		got := i64(fixed_sin(a))
		testing.expect_value(t, got, expected[i])
	}
}

// The `sin` builtin and the `tau` const evaluate through the interp over a
// hand-built node forest, returning the same Q32.32 bits the kernel produces:
// `sin(angle)` dispatches eval_named_call's new arm, and a bare `tau` name reads
// TAU_FIXED on the name-read path (the fallback after a module const). Mirrors
// the interp_test eval_length_call node-forest pattern (heap-allocated slices so
// the forest escapes this frame).
@(test)
test_eval_sin_and_tau :: proc(t: ^testing.T) {
	program, ok := load_golden(t)
	if !ok {
		return
	}
	version := initial_version(new_world(program, context.temp_allocator), context.temp_allocator)
	interp := make_trig_interp(&program, &version)

	// `tau` reads TAU_FIXED through the name-read path.
	env := root_env()
	tau_val, tau_ok := eval_name(&interp, "tau", &env)
	testing.expect(t, tau_ok)
	testing.expect_value(t, tau_val.(Fixed), TAU_FIXED)

	// `sin(tau/4)` dispatches the builtin and folds to the kernel's exact bits.
	angle := fixed_div(TAU_FIXED, to_fixed(4))
	sin_val, sin_ok := eval_sin_call(&interp, angle)
	testing.expect(t, sin_ok)
	testing.expect_value(t, sin_val.(Fixed), fixed_sin(angle))

	// `sin(0)` through the interp is exactly Fixed(0) — the builtin honors the
	// exact-zero anchor the kernel guarantees.
	zero_val, zero_ok := eval_sin_call(&interp, Fixed(0))
	testing.expect(t, zero_ok)
	testing.expect_value(t, zero_val.(Fixed), Fixed(0))

	// Error case: `sin(v)` over a non-scalar Vec2 arg is fail-closed (ok=false) —
	// the sine of a vector is undefined, never coerced.
	_, vec_ok := eval_sin_call(&interp, Vec2{to_fixed(1), to_fixed(2)})
	testing.expect(t, !vec_ok)
}

// make_trig_interp builds a read-only interpreter over the loaded program with an
// empty input snapshot and the 60hz dt — the minimal context a trig fixture reads
// against (the tau/sin path consults no rows). Mirrors interp_test's make_interp.
@(private = "file")
make_trig_interp :: proc(program: ^Program, version: ^World_Version) -> Interp {
	dt_fields := make(map[string]Value, context.temp_allocator)
	dt_fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	time := Record_Value{type_name = "Time", fields = dt_fields}
	return new_interp(program, version, nil, empty(), time, context.temp_allocator)
}

// root_env is a fresh empty scope — the frame a const name read resolves against
// (a const closes over no locals).
@(private = "file")
root_env :: proc() -> Env {
	return Env{names = make(map[string]Value, context.temp_allocator)}
}

// eval_sin_call builds and evaluates a `sin(angle)` named-call node forest by
// hand — a `.Call` over a `.Name` callee (`sin`) with a single `.Name` arg that
// resolves the supplied value out of a seeded env — so the eval_named_call `sin`
// dispatch arm is exercised, not fixed_sin in isolation. Heap-allocates each
// slice (an Odin compound slice literal cannot escape this stack frame).
@(private = "file")
eval_sin_call :: proc(interp: ^Interp, arg: Value) -> (result: Value, ok: bool) {
	callee := Node{kind = .Name, fields = trig_node_fields("sin")}
	arg_node := Node{kind = .Name, fields = trig_node_fields("a")}
	call := Node {
		kind     = .Call,
		children = trig_node_children(callee, arg_node),
	}
	env := Env {
		names = make(map[string]Value, context.temp_allocator),
	}
	env.names["a"] = arg
	return eval(interp, &call, &env)
}

// trig_node_fields heap-allocates a node's scalar-token slice from the temp arena
// so a hand-built node escapes its constructing stack frame.
@(private = "file")
trig_node_fields :: proc(tokens: ..string) -> []string {
	out := make([]string, len(tokens), context.temp_allocator)
	copy(out, tokens)
	return out
}

// trig_node_children heap-allocates a node's child slice from the temp arena,
// mirroring trig_node_fields for the children axis.
@(private = "file")
trig_node_children :: proc(nodes: ..Node) -> []Node {
	out := make([]Node, len(nodes), context.temp_allocator)
	copy(out, nodes)
	return out
}
