package funpack

import "core:testing"

@(test)
test_stub_fallback_value_observed :: proc(t: ^testing.T) {
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
