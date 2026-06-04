package funpack

import "core:testing"

@(test)
test_pipeline_trivial_assert_passes :: proc(t: ^testing.T) {
	source := "test \"to_fixed lifts Int into Fixed\" {\n\tassert to_fixed(2) == 2.0\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

@(test)
test_pipeline_failing_assert_counts_fail :: proc(t: ^testing.T) {
	source := "test \"three is not two\" {\n\tassert to_fixed(3) == 2.0\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 1)
	testing.expect_value(t, report.exit_code, 1)
}

@(test)
test_pipeline_rejects_implicit_int_promotion :: proc(t: ^testing.T) {
	// No implicit Int → Fixed promotion (spec §10): a bare Int against
	// a Fixed literal is a type error, not a coercion.
	source := "test \"promotion is explicit\" {\n\tassert 2 == 2.0\n}\n"
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_pipeline_malformed_source_is_parse_error :: proc(t: ^testing.T) {
	_, err := run_test_pipeline("garbage\n")
	testing.expect_value(t, err, Pipeline_Error.Parse_Failed)
}

@(test)
test_pipeline_empty_source_is_noop_pass :: proc(t: ^testing.T) {
	report, err := run_test_pipeline("")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}
