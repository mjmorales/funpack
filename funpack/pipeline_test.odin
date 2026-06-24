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

// The end-to-end Assert_Failure population: the test-runner pipeline fills the
// localized body (test_name, source line, expression text, operator, evaluated
// operand displays) from a LIVE source — the half the pure-renderer byte-pins in
// diagnostics_test do not reach (those construct Assert_Failure by hand). One
// per-failure row in evaluation order is the human body the CLI renders beside
// the machine count.

@(test)
test_pipeline_failed_eq_assert_carries_localized_operands :: proc(t: ^testing.T) {
	// A failing top-level == assert records ONE Assert_Failure with the test name,
	// the assert's source line, the canonical expression text, the operator, and
	// the evaluated LHS/RHS displays — populated end-to-end from the source.
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
	testing.expect_value(t, f.line, 3) // import, test, assert
	testing.expect_value(t, f.expr_text, "len([1, 2]) == 3")
	testing.expect_value(t, f.has_operands, true)
	testing.expect_value(t, f.op, "==")
	testing.expect_value(t, f.lhs_display, "2")
	testing.expect_value(t, f.rhs_display, "3")
}

@(test)
test_pipeline_failed_bare_predicate_carries_no_operands :: proc(t: ^testing.T) {
	// A bare-Bool assert (not a top-level ==/!=) records a failure with the
	// expression text but no operands — the renderer shows the expression alone.
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
	// A clean run records zero failures — the failures slice is the human body
	// beside the machine count, empty when nothing failed.
	source := "test \"ok\" {\n  assert 1 == 1\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.failed, 0)
	testing.expect_value(t, len(report.failures), 0)
}

@(test)
test_pipeline_bool_literals_evaluate :: proc(t: ^testing.T) {
	// §02 §2 Bool literals end to end: a Bool comparison asserts against
	// `true`/`false` through typecheck and evaluation — the pong overlaps
	// rail test's miss cases are this form.
	source := "test \"bool literals compare\" {\n\tassert (1.0 < 2.0) == true\n\tassert (2.0 < 1.0) == false\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
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
test_parse_uppercamel_callee_is_command_wrap_shape :: proc(t: ^testing.T) {
	// An UpperCamel name in callee position is the command-wrap call shape
	// (Spawn(thing), Despawn()) — grammar/fun.ll1.md §5A resolves command
	// wrap to plain call syntax, so `Ʉ '(' … ')'` is a structurally valid
	// call, not a parse-level casing error. A bad callee like `ToFixed(2)`
	// (no such function) is therefore caught at resolution, not at parse —
	// mirroring the variant-selector case below.
	source := "test \"x\" {\nassert ToFixed(2) == 2.0\n}\n"
	_, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.None)
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_parse_mixed_case_value_position_rejected :: proc(t: ^testing.T) {
	// A Mixed-case name (fooBar — matches no sanctioned class, spec §02) in
	// a value position is still a parse-level Wrong_Case, the casing-is-
	// structural floor that survives the command-wrap loosening.
	tokens := stage_lex("test \"x\" {\nassert fooBar == 2.0\n}\n")
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
test_pipeline_if_expr_arm_value_golden :: proc(t: ^testing.T) {
	// arena_game's literal usage end to end: a value-producing if-expression in a
	// match-arm body (arena_game.fun line 38, the `nearest_player` nearest-wins
	// fold — `Option::Some(b) => if p < b { Option::Some(p) } else {
	// Option::Some(b) }`). The fold starts None, takes the first element, then
	// keeps the smaller of (current, best) via the if-expr. Both arms are
	// Option[Fixed], so the if-expression unifies to Option[Fixed] and evaluates
	// the chosen branch. Result: Some(3.0), the nearest of 9.0 and 3.0.
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
	// NEGATIVE: a value-producing if-expression with no `else` arm is a parse
	// failure (.Missing_Else surfaced as Pipeline_Error.Parse_Failed) — both arms
	// are required in value position, never a silent fallback (spec §02 §5). Here
	// `if` parses as an atom (an assert value), so the expression-form
	// else-requirement fires rather than the statement-form early-return.
	_, err := run_golden_asserts("assert (if 1.0 < 2.0 { 10.0 }) == 10.0\n")
	testing.expect_value(t, err, Pipeline_Error.Parse_Failed)
}

@(test)
test_pipeline_if_expr_missing_else_precise_parse_error :: proc(t: ^testing.T) {
	// The same missing-else, asserted as the precise Parse_Error.Missing_Else at
	// the parse stage — the diagnostic an agent repairs against, distinct from a
	// generic Unexpected_Token.
	source := "test \"x\" {\n  assert (if 1.0 < 2.0 { 10.0 }) == 10.0\n}\n"
	_, parse_err := stage_parse(stage_lex(source))
	testing.expect_value(t, parse_err, Parse_Error.Missing_Else)
}

@(test)
test_pipeline_tuple_pattern_arity_mismatch_is_typecheck_failed :: proc(t: ^testing.T) {
	// NEGATIVE: a tuple match pattern whose positional arity disagrees with its
	// Tuple-typed scrutinee is a typecheck failure (.Tuple_Pattern_Arity surfaced
	// as Pipeline_Error.Typecheck_Failed) — a 3-position pattern over the 2-tuple
	// `(checked_div(…), 5.0)` can never bind coherently, so it is a precise
	// compile error rather than a silent nil-bound position (spec §02 §5).
	_, err := run_golden_asserts(
		"assert (match (checked_div(6.0, 2.0), 5.0) {\n" +
		"  (Option::Some(wp), rest, extra) => wp\n" +
		"  (Option::None,     _,    _)     => 0.0\n" +
		"}) == 3.0\n")
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_pipeline_if_expr_takes_each_branch :: proc(t: ^testing.T) {
	// A bare if-expression takes the consequent on a true guard and the alternate
	// on a false guard — the two-way evaluation arena's nearest-wins relies on,
	// pinned directly with both branch outcomes.
	report, err := run_golden_asserts(
		"assert (if 1.0 < 2.0 { 10.0 } else { 20.0 }) == 10.0\n" +
		"assert (if 2.0 < 1.0 { 10.0 } else { 20.0 }) == 20.0\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_tuple_match_pattern_golden :: proc(t: ^testing.T) {
	// arena_game's literal usage end to end: a positional tuple match pattern
	// over a Tuple-typed scrutinee (arena_game.fun lines 62-65, the
	// `route.advance(...)` destructure — `(Option::Some(wp), rest) => …` /
	// `(Option::None, _) => …`). The scrutinee is the tuple `(checked_div(6.0,
	// 2.0), 5.0)` whose first position is Option[Fixed] Some(3.0); the
	// `(Option::Some(wp), rest)` arm binds `wp` to 3.0 and `rest` to 5.0, and the
	// arm body reads `wp`. Result: 3.0.
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
	// The same tuple-match shape takes its `(Option::None, _)` arm when the first
	// position is None — `checked_div(1.0, 0.0)` divides by zero to None, so the
	// destructure falls to the second arm and the `rest` position is wildcarded.
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
test_pipeline_fold_body_mismatch_rejected :: proc(t: ^testing.T) {
	// acc infers Fixed from the init, x infers Int from the list — the
	// body's acc + x mixes them, which no implicit promotion saves.
	_, err := run_golden_asserts("assert fold([1, 2], 0.0, fn(acc, x) { return acc + x }) == 3.0\n")
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_pipeline_fold_wrong_arity_rejected :: proc(t: ^testing.T) {
	// fold's expected function type is (A, T) -> A: a one-param lambda
	// cannot take that shape.
	_, err := run_golden_asserts("assert fold([1.0], 0.0, fn(x) { return x }) == 1.0\n")
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_pipeline_fold_body_result_must_be_accumulator :: proc(t: ^testing.T) {
	// The body comes back Bool while the accumulator is Fixed.
	_, err := run_golden_asserts("assert fold([1.0], 0.0, fn(acc, x) { return acc == x }) == 0.0\n")
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_pipeline_fold_closure_reference_typechecks :: proc(t: ^testing.T) {
	// A combinator lambda is a closure: its body sees the enclosing scope
	// with the inferred params laid over it (the paddle_bounce predicate
	// reads `self`). So a fold body referencing a let-bound `y` types (y is
	// Fixed in scope, acc + y is Fixed) and evaluates — the captured env
	// carries y to the application frame.
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
test_exit_code_contract :: proc(t: ^testing.T) {
	// The funpack test CLI's exit contract: compile errors are 2 (never
	// a counted failure), failed assertions 1, all-pass 0. A gate violation
	// and a behavior-contract node-check violation are both compile errors,
	// so they share the 2 exit code.
	testing.expect_value(t, test_exit_code(.Typecheck_Failed, Test_Report{}), 2)
	testing.expect_value(t, test_exit_code(.Parse_Failed, Test_Report{}), 2)
	testing.expect_value(t, test_exit_code(.Gate_Failed, Test_Report{}), 2)
	testing.expect_value(t, test_exit_code(.Contract_Failed, Test_Report{}), 2)
	testing.expect_value(t, test_exit_code(.None, Test_Report{passed = 1, failed = 1}), 1)
	testing.expect_value(t, test_exit_code(.None, Test_Report{passed = 30}), 0)
}

@(test)
test_pipeline_gate_stage_passes_golden_source :: proc(t: ^testing.T) {
	// The gate stage is transparent to a clean source: it clears
	// stage_gates and reaches typecheck unchanged.
	source := with_golden_imports("test \"gate seam is transparent\" {\n\tassert to_fixed(2) == 2.0\n}\n")
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

// parse_only lexes + parses an assert-only test block and returns just
// the parse verdict, so a gate fixture can assert it parses cleanly
// before measuring the gate (a parse failure would otherwise mask the
// gate signal).
parse_only :: proc(asserts: string) -> Parse_Error {
	source := strings.concatenate({"test \"gate\" {\n", asserts, "}\n"}, context.temp_allocator)
	_, err := stage_parse(stage_lex(source))
	return err
}

// gate_error_of lexes + parses an assert-only test block (no imports, so
// the gate stage sees the bare AST it runs on) and returns the gate
// verdict directly — the gate walk is name-resolution-free, so an
// over-budget fixture need not bind its free names.
gate_error_of :: proc(asserts: string) -> Gate_Error {
	source := strings.concatenate({"test \"gate\" {\n", asserts, "}\n"}, context.temp_allocator)
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return .None // a parse failure is a separate signal; surfaced by the parse assertion in the caller
	}
	return stage_gates(ast)
}

// CHAIN_11_SHORT_CIRCUITS is one assert chaining 11 `or` short-circuits
// across 12 names — cyclomatic complexity 1 + 11 = 12, one over the
// MAX_CYCLOMATIC budget of 10.
CHAIN_11_SHORT_CIRCUITS :: "assert a or b or c or d or e or f or g or h or i or j or k or l\n"

@(test)
test_gate_cyclomatic_over_budget_chain :: proc(t: ^testing.T) {
	// Eleven and/or short-circuits push complexity to 12, over the budget
	// of 10 — the cyclomatic gate fires its dedicated arm.
	parse_err := parse_only(CHAIN_11_SHORT_CIRCUITS)
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect_value(t, gate_error_of(CHAIN_11_SHORT_CIRCUITS), Gate_Error.Cyclomatic_Exceeded)
}

@(test)
test_pipeline_cyclomatic_over_budget_is_gate_failed :: proc(t: ^testing.T) {
	// Through the whole pipeline the same over-budget chain rejects as
	// Gate_Failed — a structural compile error, never a counted test.
	source := strings.concatenate({"test \"chain\" {\n", CHAIN_11_SHORT_CIRCUITS, "}\n"}, context.temp_allocator)
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
}

@(test)
test_gate_cyclomatic_at_budget_clears :: proc(t: ^testing.T) {
	// Nine short-circuits give complexity 10 — exactly the budget, so the
	// gate clears: the ceiling is inclusive, only the eleventh-over case
	// fires.
	chain := "assert a or b or c or d or e or f or g or h or i or j\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

// NEST_4_CALLS nests four calls in argument position — compositional
// depth 4, one over the MAX_NESTING_DEPTH budget of 3. Member chains and
// operator spines stay flat, so only genuine container nesting counts.
NEST_4_CALLS :: "assert to_fixed(to_fixed(to_fixed(to_fixed(2)))) == 2.0\n"

@(test)
test_gate_nesting_over_budget_calls :: proc(t: ^testing.T) {
	// Four nested calls reach compositional depth 4, over the budget of 3
	// — the nesting gate fires its dedicated arm.
	parse_err := parse_only(NEST_4_CALLS)
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect_value(t, gate_error_of(NEST_4_CALLS), Gate_Error.Nesting_Exceeded)
}

@(test)
test_pipeline_nesting_over_budget_is_gate_failed :: proc(t: ^testing.T) {
	// Through the whole pipeline the over-nested expression rejects as
	// Gate_Failed before typecheck ever sees it.
	source := strings.concatenate({"test \"nest\" {\n", NEST_4_CALLS, "}\n"}, context.temp_allocator)
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
}

@(test)
test_gate_nesting_at_budget_clears :: proc(t: ^testing.T) {
	// Three nested calls reach depth 3 — exactly the budget, so the gate
	// clears: only the fourth level fires.
	chain := "assert to_fixed(to_fixed(to_fixed(2))) == 2.0\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

@(test)
test_gate_nesting_member_chain_stays_flat :: proc(t: ^testing.T) {
	// A deep member chain off a call is not compositional nesting:
	// `Quat.identity.rotate(v)`-style chains sit at depth 1 (the one
	// call), so they clear with room to spare — the metric measures
	// containers, not member-access edges.
	chain := "assert Quat.identity.rotate.compose.fold(v) == v\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

@(test)
test_gate_combinator_inline_predicate_is_one_level :: proc(t: ^testing.T) {
	// A combinator with an inline predicate (`filter(src, fn(c){ … })`) is ONE
	// composition level, not two: the call's argument level and the lambda's
	// closure level collapse into one (gates.odin arg_nesting_depth). So snake's
	// `filter(all_cells(), fn(c){ not contains(cells(snake), c) })` — combinator(1)
	// + contains call(1) + cells call(1) = depth 3 — clears the budget exactly,
	// matching the spec golden (snake.fun is a sanctioned example). Without the
	// collapse the lambda would double-count to depth 4 and false-fire the gate.
	chain := "assert filter(all_cells(), fn(c) { return not contains(cells(snake), c) }) == empty\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

@(test)
test_gate_combinator_predicate_body_still_deepens :: proc(t: ^testing.T) {
	// The collapse is only the lambda's OWN level: genuine nesting inside the
	// predicate body still counts. A predicate whose body nests three calls —
	// combinator(1) + a(1) + b(1) + c(1) = depth 4 — overshoots the budget, so the
	// gate fires THROUGH the inline predicate. The combinator idiom is flattened,
	// not the computation buried in it.
	chain := "assert filter(xs, fn(c) { return a(b(c(c))) }) == empty\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.Nesting_Exceeded)
}

@(test)
test_gate_bare_variant_is_a_flat_atom :: proc(t: ^testing.T) {
	// A bare enum variant is a 0-arg constructor — a value atom, not a
	// compositional container (spec §03 §2). So a list of records each
	// carrying a bare variant field nests call(0)→list(1)→record(1)→bare-
	// variant(0) = 2, NOT 3: the pong `tally` assert shape clears the
	// nesting gate.
	chain := "assert tally([Goal{side: Side::Left}, Goal{side: Side::Left}]) == 2\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

@(test)
test_gate_payload_variant_chain_rejects_at_chain_depth :: proc(t: ^testing.T) {
	// A VARIANT-OF-VARIANT chain re-bounds the pure-aggregate gaming vector:
	// each payload variant whose immediate payload is ITSELF a payload variant
	// opens a nesting level, so a constructor chain is NOT flat. The chain
	// `Box::A(Box::B(Box::C(Box::D(1))))` scores Box::A(1, payload is a variant)
	// → Box::B(1, payload is a variant) → Box::C(1, payload is a variant) →
	// Box::D(0, payload is the leaf `1`) = depth 3; wrapped in the `wrap(…)`
	// call(1) it reaches depth 4, over the budget of 3 — the gate fires. This is
	// the gaming bound the records/lists-are-transparent ADR relies on:
	// single-wrap transparency (the test below) is admitted, but each chain link
	// still counts so deep constructor nesting cannot game the budget to depth 0.
	chain := "assert wrap(Box::A(Box::B(Box::C(Box::D(1))))) == 1\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.Nesting_Exceeded)
}

@(test)
test_gate_single_wrap_payload_variant_is_transparent :: proc(t: ^testing.T) {
	// A SINGLE-WRAP payload variant — one whose immediate payload is a record,
	// list, or leaf rather than another payload variant — is a transparent
	// aggregate: it passes its payload's depth through WITHOUT opening a level.
	// `Option::Some(Vec2{x: p.x, y: p.y})` scores wrap call(1)→arg
	// Option::Some(0, over a record)→record(0, transparent)→member chains(0) =
	// depth 1, well under budget. This is the §24 yard shape — Option::Some(...)
	// wrapping a value is the same flat construction `Vec2{x, y}` already is —
	// and pins the transparency directly so it can never regress alongside the
	// chain bound. The earlier 3-link chain `Box::A(Box::B(Box::C(1)))` now
	// scores depth 3 under this narrowed metric (innermost C wraps a leaf, so it
	// is transparent), which is why the gaming-bound fixture above uses a 4-link
	// chain to land squarely over the budget.
	chain := "assert wrap(Option::Some(Vec2{x: p.x, y: p.y})) == p\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

@(test)
test_gate_yard_fold_match_with_option_clears_budget :: proc(t: ^testing.T) {
	// The exact yard `on_persist_result` shape that drove the v5 nesting-metric
	// refinement: `fold(coll, init, fn(m, r) { return match r.result {
	// Result::Ok(_) => m with { status: Option::Some("saved") } ... } })`. Under
	// the old metric this was depth 4 = combinator-call(1) + match-arm(1) +
	// with(1) + Option::Some payload-variant(1), over the budget of 3 — but a
	// canonical spec example (examples/yard) must clear the fixed
	// §01 P5 budget by construction, so the over-counting payload-variant level
	// was the bug. With the variant treated as a transparent aggregate the chain
	// is depth 3 = combinator(1, lambda level collapsed) + match-arm(1) + with(1),
	// at the budget. This pins the canonical example's shape directly so the
	// refinement can never silently regress to a false Nesting_Exceeded.
	chain := "assert fold(saved, self, fn(m, r) { return match r.result {\n" +
		"  Result::Ok(_)  => m with { status: Option::Some(\"saved\") }\n" +
		"  Result::Err(_) => m with { status: Option::Some(\"save failed\") }\n" +
		"} }) == self\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

@(test)
test_golden_source_clears_both_expr_gates :: proc(t: ^testing.T) {
	// The defining positive: the full golden numerics file — every real
	// assert, with its calls, records, lambdas, and member chains — clears
	// both Expr-tree gates. The shallow-asserts claim is pinned to the
	// live source, not assumed.
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
	// MAX_FN_STATEMENTS + 1 statements in one test block overshoots the
	// function-size budget, so stage_gates rejects the source as a
	// Gate_Failed compile error — never reaching typecheck or evaluation.
	body := strings.repeat("\tassert 0.0 == 0.0\n", MAX_FN_STATEMENTS + 1, context.temp_allocator)
	source := strings.concatenate({"test \"oversized\" {\n", body, "}\n"}, context.temp_allocator)
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_at_budget_test_block_clears_fn_size_gate :: proc(t: ^testing.T) {
	// Exactly MAX_FN_STATEMENTS statements sit at the budget, not over it:
	// the fn-size gate is transparent and the block evaluates normally.
	body := strings.repeat("\tassert 0.0 == 0.0\n", MAX_FN_STATEMENTS, context.temp_allocator)
	source := strings.concatenate({"test \"at budget\" {\n", body, "}\n"}, context.temp_allocator)
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, MAX_FN_STATEMENTS)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_over_arity_lambda_fires_arity_gate :: proc(t: ^testing.T) {
	// A MAX_PARAM_ARITY + 1 param lambda overshoots the arity budget. The
	// arity gate runs in stage_gates BEFORE stage_typecheck, so this
	// rejects as Gate_Failed — distinct from
	// test_pipeline_fold_wrong_arity_rejected, where a shape-mismatched
	// but in-budget lambda reaches typecheck and rejects as
	// Typecheck_Failed. This pins the gate-before-typecheck ordering.
	_, err := run_golden_asserts(
		"assert fold([1.0], 0.0, fn(a, b, c, d, e, f) { return a }) == 1.0\n")
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
}

@(test)
test_pipeline_at_arity_budget_lambda_clears_arity_gate :: proc(t: ^testing.T) {
	// A MAX_PARAM_ARITY-param lambda sits at the budget: the arity gate is
	// transparent, so the source passes stage_gates and the rejection (if
	// any) comes from typecheck's fold-shape check, not the gate.
	_, err := run_golden_asserts(
		"assert fold([1.0], 0.0, fn(a, b, c, d, e) { return a }) == 1.0\n")
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_gate_duplication_alpha_equivalent_blocks_fire :: proc(t: ^testing.T) {
	// Two test blocks whose bodies are structurally identical modulo
	// bound-name alpha-renaming: block one binds `v`/`acc`, block two
	// binds `w`/`total`, but every node shape, free name, literal, and
	// operator matches. The duplication gate alpha-normalizes the bound
	// names before hashing, so the two collide on one dup_class — a
	// compile error mapped to Gate_Failed.
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
	// The near-miss control: a rename-only variant is genuinely a
	// duplicate. Renaming the let binding (`a` → `b`) and every reference
	// to it is the entire difference between the two blocks — exactly the
	// dodge the alpha-normalization closes, so the gate still fires.
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
	// The structurally distinct control: two blocks that share a similar
	// surface but differ in node shape — different free names, different
	// literals, an extra assert — must NOT collide. The gate clears and
	// the pipeline runs both blocks to a normal pass, pinning the
	// non-collision boundary opposite the alpha-equivalent fixture.
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

// test_block_body lexes + parses a single test block and returns its
// statement body — the dup_class unit — so a gate-walk test can drive
// canon/dup_class over a body containing a tuple expression directly.
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
	// A tuple is a transparent aggregate — it passes its deepest element's
	// depth through (gates.odin nesting_depth tuple arm). A tuple whose first
	// element is four nested calls is therefore depth 4, one over the budget
	// of 3, so the nesting gate fires THROUGH the tuple — pinning that a tuple
	// expression is structurally walked, not silently skipped.
	chain := "assert (to_fixed(to_fixed(to_fixed(to_fixed(2)))), b) == c\n"
	parse_err := parse_only(chain)
	testing.expect_value(t, parse_err, Parse_Error.None)
	testing.expect_value(t, gate_error_of(chain), Gate_Error.Nesting_Exceeded)
}

@(test)
test_gate_tuple_expr_transparent_clears_at_budget :: proc(t: ^testing.T) {
	// The boundary control: the same shape with three nested calls is depth 3
	// — exactly the budget — and the tuple adds no level of its own, so it
	// clears. A regression that scored the tuple as a nesting level would push
	// this to 4 and fire the gate.
	chain := "assert (to_fixed(to_fixed(to_fixed(2))), b) == c\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

@(test)
test_gate_canon_distinguishes_structurally_different_tuples :: proc(t: ^testing.T) {
	// The dup-class canon (gates.odin canon_expr tuple arm) tags a tuple with
	// its `tuple` kind and its element subtrees, so two structurally different
	// tuples hash to different dup_class keys — a tuple is scored, not elided.
	left, left_err := test_block_body("assert pair((a, b)) == 0\n")
	right, right_err := test_block_body("assert pair((a, b, c)) == 0\n")
	testing.expect_value(t, left_err, Parse_Error.None)
	testing.expect_value(t, right_err, Parse_Error.None)
	// A 2-tuple and a 3-tuple are distinct shapes — distinct dup_class keys.
	testing.expect(t, dup_class(left) != dup_class(right))
}

@(test)
test_gate_canon_collides_alpha_equivalent_tuples :: proc(t: ^testing.T) {
	// The collision control: two tuples identical modulo bound-name renaming
	// canonicalize to the same form (bound names resolve to frame slots), so
	// they share one dup_class key — pinning that canon_expr walks the tuple's
	// elements rather than emitting an opaque constant tag.
	left, left_err := test_block_body("let x = 0\nassert pair((x, x)) == 0\n")
	right, right_err := test_block_body("let y = 0\nassert pair((y, y)) == 0\n")
	testing.expect_value(t, left_err, Parse_Error.None)
	testing.expect_value(t, right_err, Parse_Error.None)
	testing.expect(t, dup_class(left) == dup_class(right))
}

@(test)
test_gate_duplication_golden_source_clears :: proc(t: ^testing.T) {
	// The §29-faithful unit choice verified against the REAL golden file:
	// its repeated `assert a.slerp(b, …) == …` shapes live inside ONE
	// block, and no two of its twelve blocks are structurally identical —
	// so the whole-block unit clears where a per-assert unit would
	// false-positive. The full golden pipeline (passes elsewhere) is the
	// authority; here we pin specifically that the gate stage is clean.
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

// MATCH_SCRUTINEE_HEADER opens a test whose let binds an Option-typed
// scrutinee (checked_div returns Option[Fixed], spec §10), so the match
// fixtures below dispatch on a real Option value. Each fixture appends
// its own `match opt { … }` assert and closes the block.
MATCH_SCRUTINEE_HEADER :: "test \"match exhaustiveness\" {\n" +
	"\tlet opt = checked_div(6.0, 2.0)\n"

// run_match_fixture drives a match-bearing test block — the golden import
// header, the Option scrutinee let, then the given assert lines and the
// closing brace — through the full pipeline.
run_match_fixture :: proc(asserts: string) -> (report: Test_Report, err: Pipeline_Error) {
	source := strings.concatenate(
		{GOLDEN_IMPORT_HEADER, MATCH_SCRUTINEE_HEADER, asserts, "}\n"},
		context.temp_allocator,
	)
	return run_test_pipeline(source)
}

@(test)
test_pipeline_non_exhaustive_match_fires_gate :: proc(t: ^testing.T) {
	// A match on an Option scrutinee covering only Some — no None, no
	// wildcard — is non-total, so the pure-AST exhaustiveness gate rejects
	// it before typecheck (spec §02 §5: a non-total match is a compile
	// error). The verdict is Gate_Failed, distinct from a parse or
	// typecheck failure.
	_, err := run_match_fixture("\tassert match opt { Option::Some(v) => 1.0 } == 1.0\n")
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
}

@(test)
test_pipeline_exhaustive_match_clears_gate :: proc(t: ^testing.T) {
	// The control: covering both Option variants (Some and None) clears
	// the exhaustiveness gate. The proof the gate did NOT fire is that the
	// verdict is never Gate_Failed — a Gate_Failed here would mean the total
	// match was wrongly rejected as non-exhaustive. The match itself now
	// types (Some(v) binds v:Fixed, both arms Fixed), so the verdict reaches
	// the evaluator, which carries no match-evaluation path — the assert then
	// fails rather than erroring, never reflecting on the gate.
	_, err := run_match_fixture(
		"\tassert match opt { Option::Some(v) => 1.0, Option::None => 2.0 } == 1.0\n")
	testing.expect(t, err != Pipeline_Error.Gate_Failed)
}

@(test)
test_pipeline_wildcard_match_clears_gate :: proc(t: ^testing.T) {
	// A wildcard `_` arm is full coverage, so a Some + `_` match is total
	// and clears the gate even though None is never named explicitly. As
	// with the two-variant control, the proof the gate treated `_` as
	// exhaustive is that the verdict is never Gate_Failed.
	_, err := run_match_fixture(
		"\tassert match opt { Option::Some(v) => 1.0, _ => 2.0 } == 1.0\n")
	testing.expect(t, err != Pipeline_Error.Gate_Failed)
}

// USER_ENUM_HEADER declares a user enum (Side) and a scrutinee let, so the
// match fixtures below dispatch on a user-declared closed variant set the
// resolver registers into the gate's table — proving exhaustiveness is
// computed over user enums, not just Option.
USER_ENUM_HEADER :: "enum Side { Left, Right }\n" +
	"test \"user enum match\" {\n" +
	"\tlet s = Side::Left\n"

// run_user_enum_match_fixture drives a Side-scrutinee match through the
// full pipeline: the user enum declaration, the scrutinee let, the given
// assert, and the closing brace.
run_user_enum_match_fixture :: proc(asserts: string) -> (report: Test_Report, err: Pipeline_Error) {
	source := strings.concatenate(
		{USER_ENUM_HEADER, asserts, "}\n"},
		context.temp_allocator,
	)
	return run_test_pipeline(source)
}

@(test)
test_pipeline_non_exhaustive_user_enum_match_fires_gate :: proc(t: ^testing.T) {
	// A match over the user enum Side covering only Left — no Right, no
	// wildcard — is non-total. Because the resolver registers Side's variant
	// set into the gate's closed table, the exhaustiveness gate has a known
	// denominator and rejects it as Gate_Failed (spec §02 §5), exactly as it
	// does for Option.
	_, err := run_user_enum_match_fixture(
		"\tassert match s { Side::Left => 1 } == 1\n")
	testing.expect_value(t, err, Pipeline_Error.Gate_Failed)
}

@(test)
test_pipeline_exhaustive_user_enum_match_clears_gate :: proc(t: ^testing.T) {
	// Covering both Side variants (Left and Right) clears the gate — proof
	// the user enum's full set is registered, not a partial. The proof the
	// gate did not fire is that the verdict is never Gate_Failed: a
	// Gate_Failed here would mean the total user-enum match was wrongly
	// rejected. The match types over the registered Side enum (both arm
	// bodies Int), then the evaluator's missing match path fails the assert
	// rather than reflecting on the gate.
	_, err := run_user_enum_match_fixture(
		"\tassert match s { Side::Left => 1, Side::Right => 2 } == 1\n")
	testing.expect(t, err != Pipeline_Error.Gate_Failed)
}

// gate_verdict_of lex/parses a source (no name resolution — the gate walk is
// resolution-free) and returns the named gate verdict, the window the
// declaration-body gate fixtures read both the error and the offending
// declaration's name through.
gate_verdict_of :: proc(source: string) -> Gate_Verdict {
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return Gate_Verdict{}
	}
	return gate_verdict(ast)
}

@(test)
test_gate_walks_fn_body_match_over_user_enum :: proc(t: ^testing.T) {
	// The gap the gates close: a user-enum match inside a FN BODY (not a test
	// block) is gate-checked for exhaustiveness against the variant set the
	// resolver registered. A `fn` returning `match side { Side::Left => … }`
	// drops Right, so the body match is non-total and the gate rejects it —
	// naming the fn, not a test-block index (spec §02 §5 / §01 P5).
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
	// The same exhaustiveness gate over a BEHAVIOR step body: a `match side {
	// Side::Left => … }` in a behavior's step drops Right and rejects, with the
	// diagnostic anchored on the behavior's own name (not the reserved `step`,
	// not a positional index).
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
	// The control: a fn-body match covering both Side variants clears the gate,
	// proving the body walk reads the full registered variant set and does not
	// false-positive on a total match.
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
	// An over-budget fn body fires the fn-size gate with its named Gate_Error,
	// proving the gates run over declaration bodies, not just test blocks — and
	// the diagnostic names the fn (spec §01 P5: the budget is a per-declaration
	// constant). MAX_FN_STATEMENTS `let` bindings plus a return overshoot the
	// size budget.
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
	// An over-arity lambda buried in a fn body fires the arity gate, naming the
	// fn — proving the arity walk descends fn-body expressions (a lambda in a
	// return position), not just test-block asserts.
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
	// An over-nested fn-body return fires the nesting gate, naming the fn. Four
	// nested non-method calls reach compositional depth 4, over the budget of 3
	// — the same metric the test-block nesting fixtures pin, now over a fn body.
	// The overshoot is pure call-EXPRESSION composition (one `return`, no block
	// and no branch), so the verdict's cause is .Expression — the remedy that
	// fits (extract a helper / bind an intermediate `let`), not early returns.
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
	// The friction-report junction (174cbae9): pure call-expression nesting reaches
	// the ceiling with no block and no branch to early-return from
	// (`np_id(np_id(np_id(np_id(x))))` is a single `return`). The nesting gate fires
	// AND attributes the depth to .Expression, so the diagnostic prescribes
	// extract-a-helper / bind-an-intermediate-`let` — the remedy that actually drops
	// the depth — never the misleading "flatten with early returns".
	source := "fn np_id(x: Int) -> Int { return x }\n" +
		"fn np_deep(x: Int) -> Int { return np_id(np_id(np_id(np_id(x)))) }\n"
	verdict := gate_verdict_of(source)
	testing.expect_value(t, verdict.err, Gate_Error.Nesting_Exceeded)
	testing.expect_value(t, verdict.declaration, "np_deep")
	testing.expect_value(t, verdict.nesting_cause, Nesting_Cause.Expression)
}

@(test)
test_gate_block_nesting_is_block_cause :: proc(t: ^testing.T) {
	// The other side of the cause discriminator: a guard ladder reaches the ceiling
	// through accumulated `if` early-return-guard block nesting (no over-deep
	// expression — the innermost `return 1` is a leaf). Four nested guards put the
	// `return` at block depth 4, over the budget of 3, so the verdict's cause is
	// .Block — the diagnostic keeps the "flatten with early returns" remedy, which
	// DOES fit a guard ladder. Pinning both causes proves the discriminator is the
	// accumulated block depth, not the statement kind.
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
	// The defining positive over the gameplay surface: the full pong golden —
	// every fn helper and behavior step body, with its builder chains, nested
	// constructions, and user-enum body matches — clears all the structural
	// gates now that they run over declaration bodies, not just test blocks.
	source, ok := pong_source()
	if !ok {
		return
	}
	verdict := gate_verdict_of(source)
	testing.expect_value(t, verdict.err, Gate_Error.None)
}

// ── Edge 1: dup_class encodes binder COUNTS ────────────────────────────────
// A unit differing only by an unused trailing binder (a lambda param or a
// match-arm field-pun) is NOT alpha-equivalent — its binder arity differs — so
// it must NOT collide on the duplication gate. The canonical form encodes the
// count; these pin both the distinguished case and the genuine-collision
// control.

@(test)
test_gate_dup_class_lambda_param_count_distinguishes :: proc(t: ^testing.T) {
	// Two lambdas whose bodies bind the SAME slot (`return a`) but differ by one
	// unused trailing param: `fn(a, x){ a }` vs `fn(a){ a }`. Both bodies
	// canonicalize the body name to slot 0, so without the param-count tag they
	// would emit identical bytes and collide. Their parameter arities differ, so
	// they are NOT duplicates — the count tag (gates.odin canon_expr lambda arm)
	// separates their dup_class keys.
	two_param, two_err := test_block_body("assert fold(xs, 0, fn(a, x) { return a }) == 0\n")
	one_param, one_err := test_block_body("assert fold(xs, 0, fn(a) { return a }) == 0\n")
	testing.expect_value(t, two_err, Parse_Error.None)
	testing.expect_value(t, one_err, Parse_Error.None)
	testing.expect(t, dup_class(two_param) != dup_class(one_param))
}

@(test)
test_gate_dup_class_lambda_param_rename_only_still_collides :: proc(t: ^testing.T) {
	// The collision control: two lambdas of the SAME arity differing only by a
	// param rename (`fn(a, x){ a }` vs `fn(b, y){ b }`) stay alpha-equivalent —
	// the count matches and the renamed slot resolves identically — so they still
	// collide. The count tag distinguishes arity, never penalizes a pure rename.
	left, left_err := test_block_body("assert fold(xs, 0, fn(a, x) { return a }) == 0\n")
	right, right_err := test_block_body("assert fold(xs, 0, fn(b, y) { return b }) == 0\n")
	testing.expect_value(t, left_err, Parse_Error.None)
	testing.expect_value(t, right_err, Parse_Error.None)
	testing.expect(t, dup_class(left) == dup_class(right))
}

@(test)
test_gate_dup_class_arm_binder_count_distinguishes :: proc(t: ^testing.T) {
	// Two struct-payload match arms of the SAME variant whose bodies read the
	// same slot but bind different field SETS: `Shape2::Box{size} => size` (1
	// binder) vs `Shape2::Box{size, color} => size` (2 binders). canon_pattern
	// tags both `struct Shape2 Box` (it drops WHICH fields are punned), and both
	// bodies resolve `size` to slot 0, so without the arm binder-count tag the two
	// arms would canonicalize identically and the two blocks would collide. Their
	// binder arities differ — they are NOT duplicates — so the `(binders N)` tag
	// (gates.odin canon_arm) separates their keys. A `_` arm keeps each match
	// exhaustiveness-clean (Shape2 is not a closed set anyway).
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
	// The collision control for arm binders: two variant-binds arms of the same
	// arity differing only by a payload binder rename (`Option::Some(v) => v` vs
	// `Option::Some(w) => w`) stay alpha-equivalent — same binder count, renamed
	// slot resolves identically — so they still collide. The count tag never
	// splits a pure rename.
	left, left_err := test_block_body(
		"assert (match opt { Option::Some(v) => v, Option::None => 0 }) == 0\n")
	right, right_err := test_block_body(
		"assert (match opt { Option::Some(w) => w, Option::None => 0 }) == 0\n")
	testing.expect_value(t, left_err, Parse_Error.None)
	testing.expect_value(t, right_err, Parse_Error.None)
	testing.expect(t, dup_class(left) == dup_class(right))
}

// ── Edge 2: Variant_Expr.has_payload is canonicalized ──────────────────────

@(test)
test_gate_dup_class_variant_empty_payload_distinguishes :: proc(t: ^testing.T) {
	// A bare variant `Foo::Bar` (has_payload=false) and an empty-payload tuple
	// variant `Foo::Bar()` (has_payload=true, payload=[]) are different
	// constructor forms but both have an empty payload arg list, so without the
	// has_payload marker they emit identical canonical bytes and collide.
	// canon_expr now tags the empty payload `(payload)` only when has_payload is
	// set, so the two are distinct dup_class keys.
	bare, bare_err := test_block_body("assert Foo::Bar == 0\n")
	empty_payload, ep_err := test_block_body("assert Foo::Bar() == 0\n")
	testing.expect_value(t, bare_err, Parse_Error.None)
	testing.expect_value(t, ep_err, Parse_Error.None)
	testing.expect(t, dup_class(bare) != dup_class(empty_payload))
}

@(test)
test_gate_dup_class_variant_same_form_still_collides :: proc(t: ^testing.T) {
	// The collision control: two empty-payload variants of the same form
	// (`Foo::Bar()` vs `Foo::Bar()`) still collide — the has_payload tag fires
	// identically for both, so canonicalizing it never splits two genuinely
	// identical constructor forms.
	left, left_err := test_block_body("assert Foo::Bar() == 0\n")
	right, right_err := test_block_body("assert Foo::Bar() == 0\n")
	testing.expect_value(t, left_err, Parse_Error.None)
	testing.expect_value(t, right_err, Parse_Error.None)
	testing.expect(t, dup_class(left) == dup_class(right))
}

// ── Edge 3: mixed-type match coverage — single-type assumption guarded ──────

// first_match_expr lex/parses a single assert-only test block and returns the
// first Match_Expr in the first assert's expression, so the mixed-type guard
// fixture can drive check_match_total over a constructed match directly. The
// assert form is `match … { … } == …`, so the match sits on the binary's lhs.
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
	// THE GUARDED CASE: a match whose variant arms mix two DISTINCT known closed
	// types — `Option::Some(v)` and `Result::Ok(w)` (both in CLOSED_VARIANT_SETS).
	// The first-variant-arm heuristic would fix type_name="Option" and demand
	// Some+None, find None uncovered, and WRONGLY return Non_Exhaustive_Match. The
	// single-type assumption is guarded: match_mixes_closed_types detects the mix
	// and check_match_total defers to the typechecker, returning None rather than
	// mis-gating on a heuristic that cannot resolve the true dispatch type. This
	// case is unreachable while the closed sets are single-dispatch, but the guard
	// is permanent so a future multi-type entry cannot silently mis-gate.
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
	// The control opposite the guard: a SINGLE-type non-total match (only
	// `Option::Some`, no None, no wildcard) is NOT a mixed-type match, so the
	// guard does not fire and the gate still rejects it as Non_Exhaustive_Match.
	// The mixed-type guard relaxes only the genuinely-ambiguous case, never the
	// sound single-type one.
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
	// The single-type positive: a total Option match (Some + None) is not mixed
	// and clears the gate — confirming the guard left the happy path untouched.
	m, ok := first_match_expr(
		"assert (match x { Option::Some(v) => 1.0, Option::None => 2.0 }) == 0.0\n")
	testing.expect(t, ok)
	if !ok {
		return
	}
	sets := closed_variant_sets(Ast{})
	testing.expect_value(t, check_match_total(m, sets), Gate_Error.None)
}
