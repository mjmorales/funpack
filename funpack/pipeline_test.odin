package funpack

import "core:strings"
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
test_parse_wrong_case_type_position_record :: proc(t: ^testing.T) {
	// A record-literal constructor is a type position: a snake_case name
	// there is a casing compile error (spec §02), not a silent accept.
	tokens := stage_lex("test \"x\" {\nassert vec2{} == 2.0\n}\n")
	_, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_wrong_case_type_position_variant :: proc(t: ^testing.T) {
	tokens := stage_lex("test \"x\" {\nassert option::None == 2.0\n}\n")
	_, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_wrong_case_value_position :: proc(t: ^testing.T) {
	tokens := stage_lex("test \"x\" {\nassert ToFixed(2) == 2.0\n}\n")
	_, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_right_case_type_position_parses :: proc(t: ^testing.T) {
	// A correctly-cased variant selector parses to a structural AST; it
	// sits outside the thin evaluation domain, so the pipeline rejects
	// it at typecheck — never at parse, never as Wrong_Case.
	source := "test \"x\" {\nassert Option::None == 2.0\n}\n"
	_, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_pipeline_wrong_case_is_parse_failed :: proc(t: ^testing.T) {
	_, err := run_test_pipeline("test \"x\" {\nassert vec2{} == 2.0\n}\n")
	testing.expect_value(t, err, Pipeline_Error.Parse_Failed)
}

// run_golden_asserts drives a synthetic test block holding the given
// assert statements through the full pipeline.
run_golden_asserts :: proc(asserts: string) -> (report: Test_Report, err: Pipeline_Error) {
	source := strings.concatenate({"test \"golden\" {\n", asserts, "}\n"}, context.temp_allocator)
	return run_test_pipeline(source)
}

@(test)
test_pipeline_saturation_golden_values :: proc(t: ^testing.T) {
	// The spec §10 example block: saturate at the rails, never wrap.
	report, err := run_golden_asserts(
		"assert Fixed.MAX + 1.0 == Fixed.MAX\n" +
		"assert Fixed.MIN - 1.0 == Fixed.MIN\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_div_by_zero_golden_values :: proc(t: ^testing.T) {
	report, err := run_golden_asserts(
		"assert 1.0 / 0.0 == Fixed.MAX\n" +
		"assert -1.0 / 0.0 == Fixed.MIN\n" +
		"assert 0.0 / 0.0 == 0.0\n" +
		"assert 5.0 % 0.0 == 0.0\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 4)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_exact_arithmetic_golden_values :: proc(t: ^testing.T) {
	report, err := run_golden_asserts(
		"assert 0.5 * 0.5 == 0.25\n" +
		"assert 1.0 / 4.0 == 0.25\n" +
		"assert 0.25 + 0.5 == 0.75\n" +
		"assert to_fixed(2) + 0.5 == 2.5\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 4)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_rounding_golden_values :: proc(t: ^testing.T) {
	report, err := run_golden_asserts(
		"assert trunc(1.5) == 1\n" +
		"assert trunc(-1.5) == -1\n" +
		"assert floor(-1.5) == -2\n" +
		"assert round(1.5) == 2\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 4)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_clamp_lerp_golden_values :: proc(t: ^testing.T) {
	report, err := run_golden_asserts(
		"assert clamp(5.0, 0.0, 3.0) == 3.0\n" +
		"assert clamp(-1.0, 0.0, 3.0) == 0.0\n" +
		"assert lerp(0.0, 10.0, 0.5) == 5.0\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_checked_div_golden_values :: proc(t: ^testing.T) {
	report, err := run_golden_asserts(
		"assert checked_div(6.0, 2.0) == Option::Some(3.0)\n" +
		"assert checked_div(1.0, 0.0) == Option::None\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_empty_source_is_noop_pass :: proc(t: ^testing.T) {
	report, err := run_test_pipeline("")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}
