// Const-resolution cycle-guard fixtures (spec §10 totality, the closed-error
// discipline). A module-level `let` constant whose initializer transitively
// reaches itself — `let a = b` / `let b = a`, a self-reference, or the
// cross-module analogue through a whole-module handle — would recurse without
// bound and overflow the stack before the evaluator's `ok = false` fail-closed
// contract could fire. The evaluator threads ONE visited set (module-qualified
// const keys) through both const paths — eval_module_const (intra-module) and
// eval_module_qualified_const → eval_module_const (cross-module) — and on a
// revisit returns the const undeclared, so the assert reading the cyclic const
// FAILS (a counted failure) instead of trapping. No panic, no partial value.
//
// THREE obligations:
//   (intra) a single-module const cycle (`let a = b` / `let b = a`) fails
//     precisely — the run compiles, evaluates, and reports the cyclic assert as
//     a counted failure, never a stack overflow.
//   (cross) a cross-module const cycle (two mutually-importing modules whose
//     consts reference each other through whole-module handles) rides the REAL
//     run_project_pipeline route and fails the same way — the shared visited set
//     spans the cross-module boundary.
//   (diamond) a NON-cycle where two consts both reference a shared third
//     (`a.x = b.y`, `c.z = b.y`) still evaluates fine — the visited set clears
//     after each const resolves, so a legitimate re-reach is not a false cycle.
package funpack

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

// ── (intra) a single-module const cycle fails precisely ──────────────────

// test_const_cycle_intra_module_fails_closed pins the intra-module hazard
// (evaluate.odin's eval_module_const): two module-level consts whose initializers
// reference each other type clean (both annotated Int) but cannot evaluate. The
// guard catches the revisit and returns the const undeclared, so the assert
// reading `a` fails — passed = 0, failed = 1 — rather than recursing to a stack
// overflow. The run compiles (Pipeline_Error.None): a const cycle is an
// evaluation hazard, not a compile-stage reject, so it surfaces as a failed
// assertion (exit 1), the evaluator's fail-closed precedent.
@(test)
test_const_cycle_intra_module_fails_closed :: proc(t: ^testing.T) {
	source := "let a: Int = b\n" + "let b: Int = a\n" + "test \"a const cycle fails closed\" {\n" + "  assert a == 0\n" + "}\n"

	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	if err != .None {
		return
	}
	// The cyclic const never resolves, so its assert fails — counted, not trapped.
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 1)
	testing.expect_value(t, report.exit_code, 1)
}

// test_const_cycle_self_reference_fails_closed pins the degenerate one-const
// cycle (`let a = a`): the const references itself directly, the tightest cycle.
// The guard registers `a`'s key before evaluating its RHS, so the RHS's own
// reference to `a` trips immediately — the same fail-closed counted failure, no
// special-case for arity-one cycles.
@(test)
test_const_cycle_self_reference_fails_closed :: proc(t: ^testing.T) {
	source := "let a: Int = a\n" + "test \"a self-referential const fails closed\" {\n" + "  assert a == 0\n" + "}\n"

	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 1)
}

// ── (cross) a cross-module const cycle fails precisely ───────────────────

// test_const_cycle_cross_module_fails_closed pins the cross-module hazard the
// let-export story opened (eval_module_qualified_const → eval_module_const across
// the Module_Eval surface): two mutually-importing modules whose consts reference
// each other through whole-module handles. cyc_a's `let a = cyc_b.b` and cyc_b's
// `let b = cyc_a.a` form a cross-module cycle; a test in cyc_a asserting
// `cyc_b.b == 0` drives the chain cyc_b.b → cyc_a.a → cyc_b.b. The ONE visited
// set is shared by pointer across the cross-module owner_ctx, so the revisit
// trips the guard — the project compiles (no compile error) and the cyclic
// assert is a counted failure, never a stack overflow. Rides the REAL
// run_project_pipeline route off disk, exactly as src/pickups.fun would.
@(test)
test_const_cycle_cross_module_fails_closed :: proc(t: ^testing.T) {
	// cyc_a whole-module imports cyc_b and defines `a = cyc_b.b`, plus the test
	// that drives the cross-module chain. cyc_b whole-module imports cyc_a and
	// defines `b = cyc_a.a` — the mutual reference that closes the cycle.
	mod_a := "@doc(\"cross-module const cycle, side A\")\n" + "import cyc_b\n" + "let a: Int = cyc_b.b\n" + "test \"a cross-module const cycle fails closed\" {\n" + "  assert cyc_b.b == 0\n" + "}\n"
	mod_b := "@doc(\"cross-module const cycle, side B\")\n" + "import cyc_a\n" + "let b: Int = cyc_a.a\n"

	path_a := write_cycle_scratch(t, "funpack_const_cycle_a.fun", mod_a)
	path_b := write_cycle_scratch(t, "funpack_const_cycle_b.fun", mod_b)
	if path_a == "" || path_b == "" {
		return
	}
	defer os.remove(path_a)
	defer os.remove(path_b)

	sources := []Source{{path = path_a, module = "cyc_a"}, {path = path_b, module = "cyc_b"}}
	report := run_project_pipeline(sources)

	// The project compiles clean — both modules type (the consts are annotated,
	// the cross-module handles resolve); the cycle is an evaluation hazard only.
	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		return
	}
	// The cyclic cross-module const never resolves, so its assert is a counted
	// failure — the guard caught the revisit instead of overflowing the stack.
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 1)
}

// ── (diamond) a NON-cycle shared reference evaluates fine ────────────────

// test_const_diamond_non_cycle_evaluates is the false-positive guard: a const
// reached twice on DIFFERENT chains is NOT a cycle. dia_b exports `y = 7`; dia_a
// (`x = dia_b.y`) and dia_c (`z = dia_b.y`) both reference it — the diamond
// `a.x = b.y` / `c.z = b.y`. A test in dia_a reaches dia_b.y directly and through
// dia_c.z, hitting dia_b.y twice on two chains. Because the visited set CLEARS
// each const's key after it resolves, the second reach is not a false cycle — all
// asserts pass. This proves the guard is precise: it trips on a true cycle, never
// on a legitimate re-reach of a shared const.
@(test)
test_const_diamond_non_cycle_evaluates :: proc(t: ^testing.T) {
	// dia_b is the shared base const. dia_a and dia_c each reference it; dia_a's
	// test reaches dia_b.y both directly and via dia_c.z — the same const on two
	// distinct chains, which a cleared visited set evaluates fine.
	mod_b := "@doc(\"diamond base\")\n" + "let y: Int = 7\n"
	mod_c := "@doc(\"diamond side C\")\n" + "import dia_b\n" + "let z: Int = dia_b.y\n"
	mod_a := "@doc(\"diamond side A\")\n" + "import dia_b\n" + "import dia_c\n" + "let x: Int = dia_b.y\n" + "test \"a shared const reached on two chains evaluates fine\" {\n" + "  assert x == 7\n" + "  assert dia_b.y == 7\n" + "  assert dia_c.z == 7\n" + "}\n"

	path_a := write_cycle_scratch(t, "funpack_const_diamond_a.fun", mod_a)
	path_b := write_cycle_scratch(t, "funpack_const_diamond_b.fun", mod_b)
	path_c := write_cycle_scratch(t, "funpack_const_diamond_c.fun", mod_c)
	if path_a == "" || path_b == "" || path_c == "" {
		return
	}
	defer os.remove(path_a)
	defer os.remove(path_b)
	defer os.remove(path_c)

	sources := []Source {
		{path = path_a, module = "dia_a"},
		{path = path_b, module = "dia_b"},
		{path = path_c, module = "dia_c"},
	}
	report := run_project_pipeline(sources)

	testing.expect_value(t, report.index_err, Project_Pipeline_Error.None)
	testing.expect_value(t, report.module_err, Pipeline_Error.None)
	if report.module_err != .None {
		return
	}
	// All three asserts pass — the shared const evaluates on every chain.
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
}

// write_cycle_scratch writes a fixture .fun to a unique scratch path so
// run_project_pipeline reads it off disk; it returns "" (failing the test) on a
// write error. The caller removes the path via defer. The basename is unique per
// fixture so the multi-module sources of one run never collide.
write_cycle_scratch :: proc(t: ^testing.T, basename: string, source: string) -> string {
	base := scratch_base()
	uniq := fmt.tprintf("%d_%s", scratch_seq(), basename)
	path, _ := filepath.join({base, uniq}, context.temp_allocator)
	if write_err := os.write_entire_file(path, transmute([]u8)source); write_err != nil {
		testing.expect(t, false, "could not write the const-cycle scratch source")
		return ""
	}
	return path
}
