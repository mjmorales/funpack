package funpack

import "core:strings"
import "core:testing"

// GOLDEN_IMPORT_HEADER mirrors numerics.fun's import lines: pipeline
// fixtures bind their free names the same way the golden file does —
// there is no builtin fallback to lean on.
GOLDEN_IMPORT_HEADER :: "import engine.math.{Vec2, Vec3, Quat, clamp, lerp, dot, cross, length, sin, cos, to_fixed, trunc, floor, round, checked_div, pi}\n" +
	"import engine.list.fold\n"

// with_golden_imports prefixes a fixture source with the golden import
// header.
with_golden_imports :: proc(source: string) -> string {
	return strings.concatenate({GOLDEN_IMPORT_HEADER, source}, context.temp_allocator)
}

@(test)
test_pipeline_trivial_assert_passes :: proc(t: ^testing.T) {
	source := with_golden_imports("test \"to_fixed lifts Int into Fixed\" {\n\tassert to_fixed(2) == 2.0\n}\n")
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

@(test)
test_pipeline_failing_assert_counts_fail :: proc(t: ^testing.T) {
	source := with_golden_imports("test \"three is not two\" {\n\tassert to_fixed(3) == 2.0\n}\n")
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
// assert statements through the full pipeline, under the golden import
// header.
run_golden_asserts :: proc(asserts: string) -> (report: Test_Report, err: Pipeline_Error) {
	source := strings.concatenate({GOLDEN_IMPORT_HEADER, "test \"golden\" {\n", asserts, "}\n"}, context.temp_allocator)
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
test_pipeline_fold_saturation_golden_value :: proc(t: ^testing.T) {
	// The golden fold pin distinguishes direction: left-to-right gives
	// (MAX + 1.0) saturating to MAX, then - 1.0; a right fold would sum
	// the list first and yield MAX.
	report, err := run_golden_asserts(
		"assert fold([1.0, -1.0], Fixed.MAX, fn(acc, x) { return acc + x }) == Fixed.MAX - 1.0\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_let_bound_quaternion_golden_block :: proc(t: ^testing.T) {
	// The golden quaternion-identity block verbatim, lets included.
	source := with_golden_imports("test \"quaternion identity laws\" {\n" +
		"  let v = Vec3{x: 1.0, y: 2.0, z: 3.0}\n" +
		"  assert Quat.identity.rotate(v) == v\n" +
		"  assert Quat.identity.mul(Quat.identity) == Quat.identity\n" +
		"}\n")
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_let_bound_slerp_golden_block :: proc(t: ^testing.T) {
	// The golden slerp-endpoints block verbatim, lets included.
	source := with_golden_imports("test \"slerp endpoints are exact\" {\n" +
		"  let a = Quat.identity\n" +
		"  let b = Quat.axis_angle(Vec3{x: 0.0, y: 0.0, z: 1.0}, pi)\n" +
		"  assert a.slerp(b, 0.0) == a\n" +
		"  assert a.slerp(b, 1.0) == b\n" +
		"}\n")
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_lambda_frames_isolated :: proc(t: ^testing.T) {
	// A lambda parameter binds per application and never leaks into the
	// test scope: x resolves to the let binding after the fold.
	source := with_golden_imports("test \"frames\" {\n" +
		"  let x = 10.0\n" +
		"  assert fold([1.0, 2.0], 0.0, fn(acc, x) { return acc + x }) == 3.0\n" +
		"  assert x == 10.0\n" +
		"}\n")
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_unresolved_name_is_type_error :: proc(t: ^testing.T) {
	_, err := run_test_pipeline("test \"x\" {\nassert nope == 1.0\n}\n")
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_pipeline_pi_resolves_via_import :: proc(t: ^testing.T) {
	// pi binds through the engine.math import — there is no builtin
	// fallback behind it.
	source := "import engine.math.pi\ntest \"pi\" {\n  assert pi == pi\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_unimported_pi_rejected :: proc(t: ^testing.T) {
	_, err := run_test_pipeline("test \"pi\" {\n  assert pi == pi\n}\n")
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_pipeline_unimported_tau_rejected :: proc(t: ^testing.T) {
	// tau is a real surface name, but this file does not import it —
	// known spelling grants nothing without a binding.
	source := "import engine.math.pi\ntest \"tau\" {\n  assert tau == tau\n}\n"
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_pipeline_empty_source_is_noop_pass :: proc(t: ^testing.T) {
	report, err := run_test_pipeline("")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}
