package funpack

import "core:testing"

typecheck_stub :: proc(source: string) -> Type_Error {
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return .Unsupported_Expr
	}
	_, err := stage_typecheck(ast)
	return err
}

@(test)
test_stub_hole_matching_declared_return_typechecks :: proc(t: ^testing.T) {
	err := typecheck_stub("fn speed() -> Fixed @stub(Fixed)\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_stub_caller_typechecks_against_hole_type :: proc(t: ^testing.T) {
	err := typecheck_stub(
		"fn speed() -> Fixed @stub(Fixed)\n" +
		"fn use_speed() -> Fixed { return speed() }\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_stub_caller_sees_declared_signature_not_missing_body :: proc(t: ^testing.T) {
	err := typecheck_stub(
		"fn speed() -> Fixed @stub(Fixed)\n" +
		"fn use_speed() -> Int { return speed() }\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_stub_fallback_producing_hole_type_typechecks :: proc(t: ^testing.T) {
	err := typecheck_stub("fn speed() -> Fixed @stub(Fixed, 1.5)\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_stub_fallback_wrong_type_rejected :: proc(t: ^testing.T) {
	err := typecheck_stub("fn speed() -> Fixed @stub(Fixed, 1)\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_stub_hole_disagreeing_with_return_ascription_rejected :: proc(t: ^testing.T) {
	err := typecheck_stub("fn speed() -> Fixed @stub(Int)\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_stub_fallback_checks_in_decl_param_scope :: proc(t: ^testing.T) {
	err := typecheck_stub(
		"thing Ball { x: Int = 0 }\n" +
		"fn serve(b: Ball) -> Ball @stub(Ball, b)\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_stub_behavior_step_holed_typechecks :: proc(t: ^testing.T) {
	err := typecheck_stub(
		"thing Ball { x: Int = 0 }\n" +
		"behavior serve on Ball {\n" +
		"  fn step(self: Ball) -> Ball @stub(Ball)\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_stub_expr_hole_ascribes_declared_type :: proc(t: ^testing.T) {
	err := typecheck_stub("fn boost(base: Fixed) -> Fixed {\n  return base + @stub(Fixed)\n}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_stub_expr_hole_type_flows_to_enclosing_mismatch :: proc(t: ^testing.T) {
	err := typecheck_stub("fn boost(base: Fixed) -> Fixed {\n  return base + @stub(Int)\n}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_stub_expr_hole_disagreeing_with_return_rejected :: proc(t: ^testing.T) {
	err := typecheck_stub("fn boost() -> Fixed {\n  return @stub(Int)\n}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_stub_expr_fallback_wrong_type_rejected :: proc(t: ^testing.T) {
	err := typecheck_stub("fn boost() -> Fixed {\n  return @stub(Fixed, 1)\n}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_stub_expr_fallback_checks_in_enclosing_scope :: proc(t: ^testing.T) {
	err := typecheck_stub(
		"fn boost(base: Fixed) -> Fixed {\n" +
		"  let bias = base * 2.0\n" +
		"  return @stub(Fixed, bias)\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}
