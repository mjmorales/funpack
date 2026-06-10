// The §05 §2 typed-hole evaluation fixtures (P8: a @stub(T, fallback) hole
// compiles AND runs in dev — the approximation is live, so the game stays
// playable). Each fixture rides run_test_pipeline end-to-end, proving the
// fallback's value is what a test observes, that the fallback evaluates in
// the declaration's own environment (params in scope), that a holed behavior
// step runs its fallback exactly like a fn, and that reaching a
// typecheck-only @stub(T) with no fallback is the evaluator's defined
// fail-closed outcome — a counted assert failure, never a crash.
package funpack

import "core:testing"

@(test)
test_stub_fallback_value_observed :: proc(t: ^testing.T) {
	// AC (fallback runs): evaluating a fn whose body is `@stub(T, fallback)`
	// returns the fallback's value — the assert against the holed decl
	// observes 1.5, so the approximation is live in dev.
	source :=
		"fn speed() -> Fixed @stub(Fixed, 1.5)\n" +
		"test \"a stub fallback is the value a caller observes\" {\n" +
		"  assert speed() == 1.5\n" +
		"}\n"

	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

@(test)
test_stub_fallback_evaluates_in_decl_env :: proc(t: ^testing.T) {
	// AC (fallback environment): the fallback evaluates in the declaration's
	// own environment with params in scope — `@stub(Ball, b)` returns the
	// argument record, so `serve(b) == b` holds structurally.
	source :=
		"thing Ball { x: Int = 0 }\n" +
		"fn serve(b: Ball) -> Ball @stub(Ball, b)\n" +
		"test \"a param-reading fallback returns the argument\" {\n" +
		"  let b = Ball{x: 3}\n" +
		"  assert serve(b) == b\n" +
		"}\n"

	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_stub_behavior_step_fallback_runs :: proc(t: ^testing.T) {
	// AC (behavior parity): a holed behavior `step` runs its fallback exactly
	// like a fn — the §04 name.step(args) test-position invocation reaches
	// eval_user_fn over Behavior_Node.step, so `@stub(Ball, self)` echoes the
	// stepped entity back.
	source :=
		"thing Ball { x: Int = 0 }\n" +
		"behavior serve on Ball {\n" +
		"  fn step(self: Ball) -> Ball @stub(Ball, self)\n" +
		"}\n" +
		"test \"a holed step runs its fallback\" {\n" +
		"  let b = Ball{x: 4}\n" +
		"  assert serve.step(b) == b\n" +
		"}\n"

	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_stub_expr_fallback_value_observed :: proc(t: ^testing.T) {
	// AC (expression fallback runs): an expression-position hole evaluates
	// through the same eval_stub_hole funnel as a body hole — `base +
	// @stub(Fixed, 0.5)` yields base + the fallback's value, so the assert
	// observes 1.5 and the approximation is live in dev.
	source :=
		"fn boost(base: Fixed) -> Fixed {\n" +
		"  return base + @stub(Fixed, 0.5)\n" +
		"}\n" +
		"test \"an expression hole's fallback is the value the expression folds\" {\n" +
		"  assert boost(1.0) == 1.5\n" +
		"}\n"

	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

@(test)
test_stub_expr_fallback_evaluates_in_enclosing_scope :: proc(t: ^testing.T) {
	// AC (expression fallback environment): the fallback evaluates in the
	// frame at the hole's position — params AND earlier lets in scope — so
	// `@stub(Fixed, bias)` reads the let binding the body computed.
	source :=
		"fn boost(base: Fixed) -> Fixed {\n" +
		"  let bias = base * 2.0\n" +
		"  return @stub(Fixed, bias)\n" +
		"}\n" +
		"test \"an expression fallback reads the enclosing scope\" {\n" +
		"  assert boost(2.0) == 4.0\n" +
		"}\n"

	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_stub_expr_without_fallback_fails_closed :: proc(t: ^testing.T) {
	// AC (bare expression hole mirrors the bare body hole exactly): a
	// typecheck-only @stub(T) reached in expression position is the same
	// defined fail-closed no-value outcome eval_stub_hole gives a bare body
	// hole — ok = false propagates through the enclosing expression, so the
	// dev build compiles, the assert is a counted failure (exit 1), never a
	// crash or a fabricated value.
	source :=
		"fn boost(base: Fixed) -> Fixed {\n" +
		"  return base + @stub(Fixed)\n" +
		"}\n" +
		"test \"reaching a bare expression hole fails the assert\" {\n" +
		"  assert boost(1.0) == 1.0\n" +
		"}\n"

	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 1)
	testing.expect_value(t, report.exit_code, 1)
}

@(test)
test_stub_without_fallback_fails_closed :: proc(t: ^testing.T) {
	// AC (fallback-less hole is defined, dev-only): a typecheck-only @stub(T)
	// has nothing to run — the dev build compiles (Pipeline_Error.None; the
	// release gate is what forbids shipping it), and a test reaching the hole
	// observes the evaluator's fail-closed no-value outcome: the assert is a
	// counted failure (exit 1), never a crash or undefined behavior.
	source :=
		"fn speed() -> Fixed @stub(Fixed)\n" +
		"test \"reaching a fallback-less hole fails the assert\" {\n" +
		"  assert speed() == 0.0\n" +
		"}\n"

	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	if err != .None {
		return
	}
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 1)
	testing.expect_value(t, report.exit_code, 1)
}
