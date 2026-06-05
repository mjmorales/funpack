package funpack

import "core:testing"

// check_expr_source lexes and parses a single expression, then types
// it against an empty scope.
check_expr_source :: proc(source: string) -> (type: Type, err: Type_Error) {
	p := Parser{tokens = stage_lex(source)}
	expr, parse_err := parse_expression(&p)
	if parse_err != .None {
		return nil, .Unsupported_Expr
	}
	scope := make(Scope, context.temp_allocator)
	return expr_check(scope, expr)
}

@(test)
test_option_payload_types_are_distinct :: proc(t: ^testing.T) {
	// Option[Fixed] and Option[Int] are different types; Option's
	// unknown (the None element) unifies with either.
	testing.expect(t, !types_compatible(option_of(Ground_Type.Fixed), option_of(Ground_Type.Int)))
	testing.expect(t, types_compatible(option_of(Ground_Type.Fixed), option_of(Ground_Type.Fixed)))
	testing.expect(t, types_compatible(option_of(nil), option_of(Ground_Type.Fixed)))
	testing.expect(t, types_compatible(option_of(nil), option_of(Ground_Type.Int)))
}

@(test)
test_option_heads_do_not_cross :: proc(t: ^testing.T) {
	testing.expect(t, !types_compatible(option_of(Ground_Type.Fixed), list_of(Ground_Type.Fixed)))
	testing.expect(t, !types_compatible(option_of(Ground_Type.Fixed), Ground_Type.Fixed))
}

@(test)
test_variant_expr_types_carry_payload :: proc(t: ^testing.T) {
	some, err := check_expr_source("Option::Some(1.0)")
	testing.expect_value(t, err, Type_Error.None)
	some_option, is_option := some.(^Option_Type)
	testing.expect(t, is_option)
	testing.expect(t, is_ground(some_option.elem, .Fixed))

	none, none_err := check_expr_source("Option::None")
	testing.expect_value(t, none_err, Type_Error.None)
	none_option, none_is_option := none.(^Option_Type)
	testing.expect(t, none_is_option)
	testing.expect(t, none_option.elem == nil)
	testing.expect(t, types_compatible(some, none))
}

@(test)
test_list_expr_carries_element_type :: proc(t: ^testing.T) {
	type, err := check_expr_source("[1.0, 2.0]")
	testing.expect_value(t, err, Type_Error.None)
	list, is_list := type.(^List_Type)
	testing.expect(t, is_list)
	testing.expect(t, is_ground(list.elem, .Fixed))
}

@(test)
test_empty_list_element_is_unknown :: proc(t: ^testing.T) {
	type, err := check_expr_source("[]")
	testing.expect_value(t, err, Type_Error.None)
	list, is_list := type.(^List_Type)
	testing.expect(t, is_list)
	testing.expect(t, list.elem == nil)
	testing.expect(t, types_compatible(type, list_of(Ground_Type.Fixed)))
}

@(test)
test_heterogeneous_list_rejected :: proc(t: ^testing.T) {
	_, err := check_expr_source("[1.0, 2]")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_checked_div_types_as_option_of_fixed :: proc(t: ^testing.T) {
	type, err := check_expr_source("checked_div(6.0, 2.0)")
	testing.expect_value(t, err, Type_Error.None)
	option, is_option := type.(^Option_Type)
	testing.expect(t, is_option)
	testing.expect(t, is_ground(option.elem, .Fixed))
}

@(test)
test_lambda_types_as_placeholder_func :: proc(t: ^testing.T) {
	type, err := check_expr_source("fn(acc, x) { return acc + x }")
	testing.expect_value(t, err, Type_Error.None)
	func, is_func := type.(^Func_Type)
	testing.expect(t, is_func)
	testing.expect(t, func.params == nil)
}

@(test)
test_surface_signature_checked_div :: proc(t: ^testing.T) {
	overloads, found := surface_signatures("checked_div")
	testing.expect(t, found)
	testing.expect_value(t, len(overloads), 1)
	sig, is_func := overloads[0].(^Func_Type)
	testing.expect(t, is_func)
	testing.expect_value(t, len(sig.params), 2)
	testing.expect(t, is_ground(sig.params[0], .Fixed))
	result, is_option := sig.result.(^Option_Type)
	testing.expect(t, is_option)
	testing.expect(t, is_ground(result.elem, .Fixed))
}

@(test)
test_surface_signature_width_overloads :: proc(t: ^testing.T) {
	dot_overloads, dot_found := surface_signatures("dot")
	testing.expect(t, dot_found)
	testing.expect_value(t, len(dot_overloads), 2)
	length_overloads, length_found := surface_signatures("length")
	testing.expect(t, length_found)
	testing.expect_value(t, len(length_overloads), 2)
}

@(test)
test_surface_generic_combinators_have_no_table_signature :: proc(t: ^testing.T) {
	_, found := surface_signatures("fold")
	testing.expect(t, !found)
}

@(test)
test_surface_value_type_pi :: proc(t: ^testing.T) {
	type, found := surface_value_type("pi")
	testing.expect(t, found)
	testing.expect(t, is_ground(type, .Fixed))
}
