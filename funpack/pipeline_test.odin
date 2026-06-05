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
test_gate_bare_variant_is_a_flat_atom :: proc(t: ^testing.T) {
	// A bare enum variant is a 0-arg constructor — a value atom, not a
	// compositional container (spec §03 §2). So a list of records each
	// carrying a bare variant field nests call(0)→list(1)→record(1)→bare-
	// variant(0) = 2, NOT 3: the pong `tally` assert shape clears the
	// nesting gate. A payload-bearing variant still opens a level, so a
	// regression that re-counted bare variants would fire here.
	chain := "assert tally([Goal{side: Side::Left}, Goal{side: Side::Left}]) == 2\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.None)
}

@(test)
test_gate_payload_variant_still_opens_a_level :: proc(t: ^testing.T) {
	// The bare-variant fix is scoped: a payload-bearing variant nested under
	// three containers is still depth 4 and fires the gate. call(1)→arg
	// Some(2)→arg Some(3)→arg Some(4) overshoots the budget of 3.
	chain := "assert wrap(Box::A(Box::B(Box::C(1)))) == 1\n"
	testing.expect_value(t, gate_error_of(chain), Gate_Error.Nesting_Exceeded)
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
	source := "fn deep() -> Int {\n" +
		"  return f(f(f(f(1))))\n" +
		"}\n"
	verdict := gate_verdict_of(source)
	testing.expect_value(t, verdict.err, Gate_Error.Nesting_Exceeded)
	testing.expect_value(t, verdict.declaration, "deep")
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
