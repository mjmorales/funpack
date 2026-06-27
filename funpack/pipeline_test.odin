package funpack

import "core:strings"
import "core:testing"

GOLDEN_IMPORT_HEADER :: "import engine.math.{Vec2, Vec3, Quat, clamp, lerp, dot, cross, length, sin, cos, to_fixed, trunc, floor, round, checked_div, pi}\n" +
	"import engine.list.fold\n"

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
test_pipeline_failed_eq_assert_carries_localized_operands :: proc(t: ^testing.T) {
	source := "import engine.list.len\n" +
		"test \"len fails correctly\" {\n  assert len([1, 2]) == 3\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.failed, 1)
	testing.expect_value(t, len(report.failures), 1)
	if len(report.failures) != 1 {
		return
	}
	f := report.failures[0]
	testing.expect_value(t, f.test_name, "len fails correctly")
	testing.expect_value(t, f.line, 3)
	testing.expect_value(t, f.expr_text, "len([1, 2]) == 3")
	testing.expect_value(t, f.has_operands, true)
	testing.expect_value(t, f.op, "==")
	testing.expect_value(t, f.lhs_display, "2")
	testing.expect_value(t, f.rhs_display, "3")
}

@(test)
test_pipeline_failed_bare_predicate_carries_no_operands :: proc(t: ^testing.T) {
	source := "test \"flag\" {\n  assert false\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.failed, 1)
	testing.expect_value(t, len(report.failures), 1)
	if len(report.failures) != 1 {
		return
	}
	f := report.failures[0]
	testing.expect_value(t, f.test_name, "flag")
	testing.expect_value(t, f.expr_text, "false")
	testing.expect_value(t, f.has_operands, false)
}

@(test)
test_pipeline_passing_run_carries_no_failures :: proc(t: ^testing.T) {
	source := "test \"ok\" {\n  assert 1 == 1\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, len(report.failures), 0)
}

@(test)
test_pipeline_bool_literals_evaluate :: proc(t: ^testing.T) {
	source := "test \"bool literals compare\" {\n\tassert (1.0 < 2.0) == true\n\tassert (2.0 < 1.0) == false\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_rejects_implicit_int_promotion :: proc(t: ^testing.T) {
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
test_parse_uppercamel_callee_is_command_wrap_shape :: proc(t: ^testing.T) {
	source := "test \"x\" {\nassert ToFixed(2) == 2.0\n}\n"
	_, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_parse_mixed_case_value_position_rejected :: proc(t: ^testing.T) {
	tokens := stage_lex("test \"x\" {\nassert fooBar == 2.0\n}\n")
	_, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.Wrong_Case)
}

@(test)
test_parse_right_case_type_position_parses :: proc(t: ^testing.T) {
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

run_golden_asserts :: proc(asserts: string) -> (report: Test_Report, err: Pipeline_Error) {
	source := strings.concatenate({GOLDEN_IMPORT_HEADER, "test \"golden\" {\n", asserts, "}\n"}, context.temp_allocator)
	return run_test_pipeline(source)
}

@(test)
test_pipeline_saturation_golden_values :: proc(t: ^testing.T) {
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
test_pipeline_if_expr_arm_value_golden :: proc(t: ^testing.T) {
	report, err := run_golden_asserts(
		"assert fold([9.0, 3.0], Option::None, fn(acc, p) {\n" +
		"  return match acc {\n" +
		"    Option::None    => Option::Some(p)\n" +
		"    Option::Some(b) => if p < b { Option::Some(p) } else { Option::Some(b) }\n" +
		"  }\n" +
		"}) == Option::Some(3.0)\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_if_expr_missing_else_is_parse_failed :: proc(t: ^testing.T) {
	_, err := run_golden_asserts("assert (if 1.0 < 2.0 { 10.0 }) == 10.0\n")
	testing.expect_value(t, err, Pipeline_Error.Parse_Failed)
}

@(test)
test_pipeline_if_expr_missing_else_precise_parse_error :: proc(t: ^testing.T) {
	source := "test \"x\" {\n  assert (if 1.0 < 2.0 { 10.0 }) == 10.0\n}\n"
	_, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.Missing_Else)
}

@(test)
test_pipeline_tuple_pattern_arity_mismatch_is_typecheck_failed :: proc(t: ^testing.T) {
	_, err := run_golden_asserts(
		"assert (match (checked_div(6.0, 2.0), 5.0) {\n" +
		"  (Option::Some(wp), rest, extra) => wp\n" +
		"  (Option::None,     _,    _)     => 0.0\n" +
		"}) == 3.0\n")
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_pipeline_if_expr_takes_each_branch :: proc(t: ^testing.T) {
	report, err := run_golden_asserts(
		"assert (if 1.0 < 2.0 { 10.0 } else { 20.0 }) == 10.0\n" +
		"assert (if 2.0 < 1.0 { 10.0 } else { 20.0 }) == 20.0\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_tuple_match_pattern_golden :: proc(t: ^testing.T) {
	report, err := run_golden_asserts(
		"assert (match (checked_div(6.0, 2.0), 5.0) {\n" +
		"  (Option::Some(wp), rest) => wp\n" +
		"  (Option::None,     _)    => 0.0\n" +
		"}) == 3.0\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_tuple_match_takes_none_arm :: proc(t: ^testing.T) {
	report, err := run_golden_asserts(
		"assert (match (checked_div(1.0, 0.0), 5.0) {\n" +
		"  (Option::Some(wp), rest) => wp\n" +
		"  (Option::None,     _)    => 0.0\n" +
		"}) == 0.0\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_fold_saturation_golden_value :: proc(t: ^testing.T) {
	report, err := run_golden_asserts(
		"assert fold([1.0, -1.0], Fixed.MAX, fn(acc, x) { return acc + x }) == Fixed.MAX - 1.0\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_let_bound_quaternion_golden_block :: proc(t: ^testing.T) {
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
test_pipeline_fold_body_mismatch_rejected :: proc(t: ^testing.T) {
	_, err := run_golden_asserts("assert fold([1, 2], 0.0, fn(acc, x) { return acc + x }) == 3.0\n")
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_pipeline_fold_wrong_arity_rejected :: proc(t: ^testing.T) {
	_, err := run_golden_asserts("assert fold([1.0], 0.0, fn(x) { return x }) == 1.0\n")
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_pipeline_fold_body_result_must_be_accumulator :: proc(t: ^testing.T) {
	_, err := run_golden_asserts("assert fold([1.0], 0.0, fn(acc, x) { return acc == x }) == 0.0\n")
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_pipeline_fold_closure_reference_typechecks :: proc(t: ^testing.T) {
	source := with_golden_imports("test \"closure\" {\n" +
		"  let y = 1.0\n" +
		"  assert fold([1.0], 0.0, fn(acc, x) { return acc + y }) == 1.0\n" +
		"}\n")
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_unresolved_name_is_type_error :: proc(t: ^testing.T) {
	_, err := run_test_pipeline("test \"x\" {\nassert nope == 1.0\n}\n")
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_pipeline_pi_resolves_via_import :: proc(t: ^testing.T) {
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
	source := "import engine.math.pi\ntest \"tau\" {\n  assert tau == tau\n}\n"
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_exit_code_contract :: proc(t: ^testing.T) {
	testing.expect_value(t, test_exit_code(.Typecheck_Failed, Test_Report{}), 2)
	testing.expect_value(t, test_exit_code(.Parse_Failed, Test_Report{}), 2)
	testing.expect_value(t, test_exit_code(.Gate_Failed, Test_Report{}), 2)
	testing.expect_value(t, test_exit_code(.Contract_Failed, Test_Report{}), 2)
	testing.expect_value(t, test_exit_code(.None, Test_Report{passed = 1, failed = 1}), 1)
	testing.expect_value(t, test_exit_code(.None, Test_Report{passed = 30}), 0)
}

@(test)
test_pipeline_gate_stage_passes_golden_source :: proc(t: ^testing.T) {
	source := with_golden_imports("test \"gate seam is transparent\" {\n\tassert to_fixed(2) == 2.0\n}\n")
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

parse_only :: proc(asserts: string) -> Parse_Error {
	source := strings.concatenate({"test \"gate\" {\n", asserts, "}\n"}, context.temp_allocator)
	_, err := stage_parse(stage_lex(source))
	return err
}

gate_error_of :: proc(asserts: string) -> Gate_Error {
	source := strings.concatenate({"test \"gate\" {\n", asserts, "}\n"}, context.temp_allocator)
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return .None
	}
	return stage_gates(ast)
}

CHAIN_11_SHORT_CIRCUITS :: "assert a or b or c or d or e or f or g or h or i or j or k or l\n"

@(test)
test_gate_cyclomatic_over_budget_chain :: proc(t: ^testing.T) {
	parse_err := parse_only(CHAIN_11_SHORT_CIRCUITS)
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect_value(t, gate_error_of(CHAIN_11_SHORT_CIRCUITS), Gate_Error.Cyclomatic_Exceeded)
}

@(test)
test_pipeline_cyclomatic_over_budget_is_gate_failed :: proc(t: ^testing.T) {
	source := strings.concatenate({"test \"chain\" {\n", CHAIN_11_SHORT_CIRCUITS, "}\n"}, context.temp_allocator)
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
}

@(test)
test_gate_cyclomatic_at_budget_clears :: proc(t: ^testing.T) {
	chain := "assert a or b or c or d or e or f or g or h or i or j\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

NEST_4_CALLS :: "assert to_fixed(to_fixed(to_fixed(to_fixed(2)))) == 2.0\n"

@(test)
test_gate_nesting_over_budget_calls :: proc(t: ^testing.T) {
	parse_err := parse_only(NEST_4_CALLS)
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect_value(t, gate_error_of(NEST_4_CALLS), Gate_Error.Nesting_Exceeded)
}

@(test)
test_pipeline_nesting_over_budget_is_gate_failed :: proc(t: ^testing.T) {
	source := strings.concatenate({"test \"nest\" {\n", NEST_4_CALLS, "}\n"}, context.temp_allocator)
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
}

@(test)
test_gate_nesting_at_budget_clears :: proc(t: ^testing.T) {
	chain := "assert to_fixed(to_fixed(to_fixed(2))) == 2.0\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

@(test)
test_gate_nesting_member_chain_stays_flat :: proc(t: ^testing.T) {
	chain := "assert Quat.identity.rotate.compose.fold(v) == v\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

@(test)
test_gate_combinator_inline_predicate_is_one_level :: proc(t: ^testing.T) {
	chain := "assert filter(all_cells(), fn(c) { return not contains(cells(snake), c) }) == empty\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

@(test)
test_gate_combinator_predicate_body_still_deepens :: proc(t: ^testing.T) {
	chain := "assert filter(xs, fn(c) { return a(b(c(c))) }) == empty\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.Nesting_Exceeded)
}

@(test)
test_gate_bare_variant_is_a_flat_atom :: proc(t: ^testing.T) {
	chain := "assert tally([Goal{side: Side::Left}, Goal{side: Side::Left}]) == 2\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

@(test)
test_gate_payload_variant_chain_rejects_at_chain_depth :: proc(t: ^testing.T) {
	chain := "assert wrap(Box::A(Box::B(Box::C(Box::D(1))))) == 1\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.Nesting_Exceeded)
}

@(test)
test_gate_single_wrap_payload_variant_is_transparent :: proc(t: ^testing.T) {
	chain := "assert wrap(Option::Some(Vec2{x: p.x, y: p.y})) == p\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

@(test)
test_gate_yard_fold_match_with_option_clears_budget :: proc(t: ^testing.T) {
	chain := "assert fold(saved, self, fn(m, r) { return match r.result {\n" +
		"  Result::Ok(_)  => m with { status: Option::Some(\"saved\") }\n" +
		"  Result::Err(_) => m with { status: Option::Some(\"save failed\") }\n" +
		"} }) == self\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

@(test)
test_golden_source_clears_both_expr_gates :: proc(t: ^testing.T) {
	source, ok := golden_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect_value(t, stage_gates(ast), Gate_Error.None)
}

@(test)
test_pipeline_oversized_test_block_fires_fn_size_gate :: proc(t: ^testing.T) {
	body := strings.repeat("\tassert 0.0 == 0.0\n", MAX_FN_STATEMENTS + 1, context.temp_allocator)
	source := strings.concatenate({"test \"oversized\" {\n", body, "}\n"}, context.temp_allocator)
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_at_budget_test_block_clears_fn_size_gate :: proc(t: ^testing.T) {
	body := strings.repeat("\tassert 0.0 == 0.0\n", MAX_FN_STATEMENTS, context.temp_allocator)
	source := strings.concatenate({"test \"at budget\" {\n", body, "}\n"}, context.temp_allocator)
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, MAX_FN_STATEMENTS)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_over_arity_lambda_fires_arity_gate :: proc(t: ^testing.T) {
	_, err := run_golden_asserts(
		"assert fold([1.0], 0.0, fn(a, b, c, d, e, f) { return a }) == 1.0\n")
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
}

@(test)
test_pipeline_at_arity_budget_lambda_clears_arity_gate :: proc(t: ^testing.T) {
	_, err := run_golden_asserts(
		"assert fold([1.0], 0.0, fn(a, b, c, d, e) { return a }) == 1.0\n")
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_gate_duplication_alpha_equivalent_blocks_fire :: proc(t: ^testing.T) {
	source := with_golden_imports(
		"test \"first\" {\n" +
		"  let v = to_fixed(2)\n" +
		"  assert fold([1.0, 2.0], v, fn(acc, x) { return acc + x }) == 5.0\n" +
		"}\n" +
		"test \"second\" {\n" +
		"  let w = to_fixed(2)\n" +
		"  assert fold([1.0, 2.0], w, fn(total, x) { return total + x }) == 5.0\n" +
		"}\n")
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
}

@(test)
test_gate_duplication_rename_only_still_collides :: proc(t: ^testing.T) {
	source := with_golden_imports(
		"test \"alpha\" {\n" +
		"  let a = to_fixed(2)\n" +
		"  assert a + 0.5 == 2.5\n" +
		"}\n" +
		"test \"beta\" {\n" +
		"  let b = to_fixed(2)\n" +
		"  assert b + 0.5 == 2.5\n" +
		"}\n")
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
}

@(test)
test_gate_duplication_distinct_blocks_clear :: proc(t: ^testing.T) {
	source := with_golden_imports(
		"test \"trunc\" {\n" +
		"  assert trunc(1.5) == 1\n" +
		"}\n" +
		"test \"floor\" {\n" +
		"  assert floor(-1.5) == -2\n" +
		"  assert round(1.5) == 2\n" +
		"}\n")
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_gate_duplication_const_accessors_exempt :: proc(t: ^testing.T) {
	source := with_golden_imports(
		"fn map_h() -> Int { return 24 }\n" +
		"fn hud_h() -> Int { return 24 }\n" +
		"test \"knobs\" {\n" +
		"  assert map_h() + hud_h() == 48\n" +
		"}\n")
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_gate_duplication_param_fns_same_body_still_fire :: proc(t: ^testing.T) {
	source := with_golden_imports(
		"fn area_a(w: Int, h: Int) -> Int { return w * h + 1 }\n" +
		"fn area_b(w: Int, h: Int) -> Int { return w * h + 1 }\n")
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
}

test_block_body :: proc(asserts: string) -> ([]Statement, Parse_Error) {
	source := strings.concatenate({"test \"gate\" {\n", asserts, "}\n"}, context.temp_allocator)
	ast, err := stage_parse(stage_lex(source))
	if err != .None {
		return nil, err
	}
	return ast.tests[0].body, .None
}

@(test)
test_gate_tuple_expr_overshoots_nesting :: proc(t: ^testing.T) {
	chain := "assert (to_fixed(to_fixed(to_fixed(to_fixed(2)))), b) == c\n"
	parse_err := parse_only(chain)
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect_value(t, gate_error_of(chain), Gate_Error.Nesting_Exceeded)
}

@(test)
test_gate_tuple_expr_transparent_clears_at_budget :: proc(t: ^testing.T) {
	chain := "assert (to_fixed(to_fixed(to_fixed(2))), b) == c\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

@(test)
test_gate_canon_distinguishes_structurally_different_tuples :: proc(t: ^testing.T) {
	left, left_err := test_block_body("assert pair((a, b)) == 0\n")
	right, right_err := test_block_body("assert pair((a, b, c)) == 0\n")
	testing.expect_value(t, left_err, Parse_Error.None)
	testing.expect_value(t, right_err, Parse_Error.None)
	testing.expect(t, dup_class(left) != dup_class(right))
}

@(test)
test_gate_canon_collides_alpha_equivalent_tuples :: proc(t: ^testing.T) {
	left, left_err := test_block_body("let x = 0\nassert pair((x, x)) == 0\n")
	right, right_err := test_block_body("let y = 0\nassert pair((y, y)) == 0\n")
	testing.expect_value(t, left_err, Parse_Error.None)
	testing.expect_value(t, right_err, Parse_Error.None)
	testing.expect(t, dup_class(left) == dup_class(right))
}

@(test)
test_gate_dup_canon_is_identity_not_digest :: proc(t: ^testing.T) {
	a, a_err := test_block_body("let x = 0\nassert pair((x, x)) == 0\n")
	b, b_err := test_block_body("let y = 0\nassert pair((y, y)) == 0\n")
	c, c_err := test_block_body("assert pair((a, b, c)) == 0\n")
	testing.expect_value(t, a_err, Parse_Error.None)
	testing.expect_value(t, b_err, Parse_Error.None)
	testing.expect_value(t, c_err, Parse_Error.None)
	testing.expect(t, dup_canon(a) == dup_canon(b))
	testing.expect(t, dup_canon(a) != dup_canon(c))
	testing.expect_value(t, dup_class(a), dup_class(b))
}

@(test)
test_gate_duplication_golden_source_clears :: proc(t: ^testing.T) {
	source, ok := golden_source()
	if !ok {
		return
	}
	ast, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect_value(t, stage_gates(ast), Gate_Error.None)
}

@(test)
test_pipeline_empty_source_is_noop_pass :: proc(t: ^testing.T) {
	report, err := run_test_pipeline("")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, report.exit_code, 0)
}

MATCH_SCRUTINEE_HEADER :: "test \"match exhaustiveness\" {\n" +
	"\tlet opt = checked_div(6.0, 2.0)\n"

run_match_fixture :: proc(asserts: string) -> (report: Test_Report, err: Pipeline_Error) {
	source := strings.concatenate(
		{GOLDEN_IMPORT_HEADER, MATCH_SCRUTINEE_HEADER, asserts, "}\n"},
		context.temp_allocator,
	)
	return run_test_pipeline(source)
}

@(test)
test_pipeline_non_exhaustive_match_fires_gate :: proc(t: ^testing.T) {
	_, err := run_match_fixture("\tassert match opt { Option::Some(v) => 1.0 } == 1.0\n")
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
}

@(test)
test_pipeline_exhaustive_match_clears_gate :: proc(t: ^testing.T) {
	_, err := run_match_fixture(
		"\tassert match opt { Option::Some(v) => 1.0, Option::None => 2.0 } == 1.0\n")
	testing.expect(t, err != Pipeline_Error.Gate_Failed)
}

@(test)
test_pipeline_wildcard_match_clears_gate :: proc(t: ^testing.T) {
	_, err := run_match_fixture(
		"\tassert match opt { Option::Some(v) => 1.0, _ => 2.0 } == 1.0\n")
	testing.expect(t, err != Pipeline_Error.Gate_Failed)
}

USER_ENUM_HEADER :: "enum Side { Left, Right }\n" +
	"test \"user enum match\" {\n" +
	"\tlet s = Side::Left\n"

run_user_enum_match_fixture :: proc(asserts: string) -> (report: Test_Report, err: Pipeline_Error) {
	source := strings.concatenate(
		{USER_ENUM_HEADER, asserts, "}\n"},
		context.temp_allocator,
	)
	return run_test_pipeline(source)
}

@(test)
test_pipeline_non_exhaustive_user_enum_match_fires_gate :: proc(t: ^testing.T) {
	_, err := run_user_enum_match_fixture(
		"\tassert match s { Side::Left => 1 } == 1\n")
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
}

@(test)
test_pipeline_exhaustive_user_enum_match_clears_gate :: proc(t: ^testing.T) {
	_, err := run_user_enum_match_fixture(
		"\tassert match s { Side::Left => 1, Side::Right => 2 } == 1\n")
	testing.expect(t, err != Pipeline_Error.Gate_Failed)
}

gate_verdict_of :: proc(source: string) -> Gate_Verdict {
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return Gate_Verdict{}
	}
	return gate_verdict(ast)
}

@(test)
test_gate_walks_fn_body_match_over_user_enum :: proc(t: ^testing.T) {
	source := "enum Side { Left, Right }\n" +
		"fn pick(side: Side) -> Int {\n" +
		"  return match side {\n" +
		"    Side::Left => 1\n" +
		"  }\n" +
		"}\n"
	verdict := gate_verdict_of(source)
	testing.expect_value(t, verdict.err, Gate_Error.Non_Exhaustive_Match)
	testing.expect_value(t, verdict.declaration, "pick")
}

@(test)
test_gate_walks_behavior_step_match_over_user_enum :: proc(t: ^testing.T) {
	source := "enum Side { Left, Right }\n" +
		"thing Paddle { defends: Side }\n" +
		"behavior classify on Paddle {\n" +
		"  fn step(self: Paddle) -> Int {\n" +
		"    return match self.defends {\n" +
		"      Side::Left => 1\n" +
		"    }\n" +
		"  }\n" +
		"}\n"
	verdict := gate_verdict_of(source)
	testing.expect_value(t, verdict.err, Gate_Error.Non_Exhaustive_Match)
	testing.expect_value(t, verdict.declaration, "classify")
}

@(test)
test_gate_complete_fn_body_match_clears :: proc(t: ^testing.T) {
	source := "enum Side { Left, Right }\n" +
		"fn pick(side: Side) -> Int {\n" +
		"  return match side {\n" +
		"    Side::Left => 1\n" +
		"    Side::Right => 2\n" +
		"  }\n" +
		"}\n"
	verdict := gate_verdict_of(source)
	testing.expect_value(t, verdict.err, Gate_Error.None)
}

@(test)
test_gate_oversized_fn_body_fires_named_fn_size :: proc(t: ^testing.T) {
	lets := strings.repeat("  let n = 1\n", MAX_FN_STATEMENTS, context.temp_allocator)
	source := strings.concatenate(
		{"fn oversized() -> Int {\n", lets, "  return 1\n}\n"},
		context.temp_allocator,
	)
	verdict := gate_verdict_of(source)
	testing.expect_value(t, verdict.err, Gate_Error.Fn_Size_Exceeded)
	testing.expect_value(t, verdict.declaration, "oversized")
}

@(test)
test_gate_over_arity_fn_body_lambda_fires_named_arity :: proc(t: ^testing.T) {
	source := "fn build() -> Int {\n" +
		"  let f = fn(a, b, c, d, e, f) { return a }\n" +
		"  return 1\n" +
		"}\n"
	verdict := gate_verdict_of(source)
	testing.expect_value(t, verdict.err, Gate_Error.Arity_Exceeded)
	testing.expect_value(t, verdict.declaration, "build")
}

@(test)
test_gate_over_nested_fn_body_fires_named_nesting :: proc(t: ^testing.T) {
	source := "fn deep() -> Int {\n" +
		"  return f(f(f(f(1))))\n" +
		"}\n"
	verdict := gate_verdict_of(source)
	testing.expect_value(t, verdict.err, Gate_Error.Nesting_Exceeded)
	testing.expect_value(t, verdict.declaration, "deep")
	testing.expect_value(t, verdict.nesting_cause, Nesting_Cause.Expression)
}

@(test)
test_gate_call_nesting_is_expression_cause :: proc(t: ^testing.T) {
	source := "fn np_id(x: Int) -> Int { return x }\n" +
		"fn np_deep(x: Int) -> Int { return np_id(np_id(np_id(np_id(x)))) }\n"
	verdict := gate_verdict_of(source)
	testing.expect_value(t, verdict.err, Gate_Error.Nesting_Exceeded)
	testing.expect_value(t, verdict.declaration, "np_deep")
	testing.expect_value(t, verdict.nesting_cause, Nesting_Cause.Expression)
}

@(test)
test_gate_block_nesting_is_block_cause :: proc(t: ^testing.T) {
	source := "fn deep() -> Int {\n" +
		"  if true {\n" +
		"    if true {\n" +
		"      if true {\n" +
		"        if true {\n" +
		"          return 1\n" +
		"        }\n" +
		"      }\n" +
		"    }\n" +
		"  }\n" +
		"  return 0\n" +
		"}\n"
	verdict := gate_verdict_of(source)
	testing.expect_value(t, verdict.err, Gate_Error.Nesting_Exceeded)
	testing.expect_value(t, verdict.declaration, "deep")
	testing.expect_value(t, verdict.nesting_cause, Nesting_Cause.Block)
}

@(test)
test_gate_pong_golden_clears_with_declaration_bodies :: proc(t: ^testing.T) {
	source, ok := pong_source()
	if !ok {
		return
	}
	verdict := gate_verdict_of(source)
	testing.expect_value(t, verdict.err, Gate_Error.None)
}

@(test)
test_gate_dup_class_lambda_param_count_distinguishes :: proc(t: ^testing.T) {
	two_param, two_err := test_block_body("assert fold(xs, 0, fn(a, x) { return a }) == 0\n")
	one_param, one_err := test_block_body("assert fold(xs, 0, fn(a) { return a }) == 0\n")
	testing.expect_value(t, two_err, Parse_Error.None)
	testing.expect_value(t, one_err, Parse_Error.None)
	testing.expect(t, dup_class(two_param) != dup_class(one_param))
}

@(test)
test_gate_dup_class_lambda_param_rename_only_still_collides :: proc(t: ^testing.T) {
	left, left_err := test_block_body("assert fold(xs, 0, fn(a, x) { return a }) == 0\n")
	right, right_err := test_block_body("assert fold(xs, 0, fn(b, y) { return b }) == 0\n")
	testing.expect_value(t, left_err, Parse_Error.None)
	testing.expect_value(t, right_err, Parse_Error.None)
	testing.expect(t, dup_class(left) == dup_class(right))
}

@(test)
test_gate_dup_class_arm_binder_count_distinguishes :: proc(t: ^testing.T) {
	one_binder, one_err := test_block_body(
		"assert (match shape { Shape2::Box{size} => size, _ => 0 }) == 0\n")
	two_binder, two_err := test_block_body(
		"assert (match shape { Shape2::Box{size, color} => size, _ => 0 }) == 0\n")
	testing.expect_value(t, one_err, Parse_Error.None)
	testing.expect_value(t, two_err, Parse_Error.None)
	testing.expect(t, dup_class(one_binder) != dup_class(two_binder))
}

@(test)
test_gate_dup_class_arm_binder_rename_only_still_collides :: proc(t: ^testing.T) {
	left, left_err := test_block_body(
		"assert (match opt { Option::Some(v) => v, Option::None => 0 }) == 0\n")
	right, right_err := test_block_body(
		"assert (match opt { Option::Some(w) => w, Option::None => 0 }) == 0\n")
	testing.expect_value(t, left_err, Parse_Error.None)
	testing.expect_value(t, right_err, Parse_Error.None)
	testing.expect(t, dup_class(left) == dup_class(right))
}

@(test)
test_gate_dup_class_variant_empty_payload_distinguishes :: proc(t: ^testing.T) {
	bare, bare_err := test_block_body("assert Foo::Bar == 0\n")
	empty_payload, ep_err := test_block_body("assert Foo::Bar() == 0\n")
	testing.expect_value(t, bare_err, Parse_Error.None)
	testing.expect_value(t, ep_err, Parse_Error.None)
	testing.expect(t, dup_class(bare) != dup_class(empty_payload))
}

@(test)
test_gate_dup_class_variant_same_form_still_collides :: proc(t: ^testing.T) {
	left, left_err := test_block_body("assert Foo::Bar() == 0\n")
	right, right_err := test_block_body("assert Foo::Bar() == 0\n")
	testing.expect_value(t, left_err, Parse_Error.None)
	testing.expect_value(t, right_err, Parse_Error.None)
	testing.expect(t, dup_class(left) == dup_class(right))
}

first_match_expr :: proc(asserts: string) -> (^Match_Expr, bool) {
	body, err := test_block_body(asserts)
	if err != .None || len(body) == 0 {
		return nil, false
	}
	assert_node, is_assert := body[0].(Assert_Node)
	if !is_assert {
		return nil, false
	}
	binary, is_binary := assert_node.expr.(^Binary_Expr)
	if !is_binary {
		return nil, false
	}
	m, is_match := binary.lhs.(^Match_Expr)
	return m, is_match
}

@(test)
test_gate_mixed_type_match_is_skipped_not_misgated :: proc(t: ^testing.T) {
	m, ok := first_match_expr(
		"assert (match x { Option::Some(v) => 1.0, Result::Ok(w) => 2.0 }) == 0.0\n")
	testing.expect(t, ok)
	if !ok {
		return
	}
	sets := closed_variant_sets(Ast{})
	testing.expect_value(t, check_match_total(m, sets), Gate_Error.None)
}

@(test)
test_gate_single_type_non_exhaustive_still_fires :: proc(t: ^testing.T) {
	m, ok := first_match_expr(
		"assert (match x { Option::Some(v) => 1.0 }) == 0.0\n")
	testing.expect(t, ok)
	if !ok {
		return
	}
	sets := closed_variant_sets(Ast{})
	testing.expect_value(t, check_match_total(m, sets), Gate_Error.Non_Exhaustive_Match)
}

@(test)
test_gate_single_type_exhaustive_clears :: proc(t: ^testing.T) {
	m, ok := first_match_expr(
		"assert (match x { Option::Some(v) => 1.0, Option::None => 2.0 }) == 0.0\n")
	testing.expect(t, ok)
	if !ok {
		return
	}
	sets := closed_variant_sets(Ast{})
	testing.expect_value(t, check_match_total(m, sets), Gate_Error.None)
}
