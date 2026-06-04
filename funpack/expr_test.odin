package funpack

import "core:testing"

parse_expr_text :: proc(source: string) -> (Expr, Parse_Error) {
	p := Parser{tokens = stage_lex(source)}
	return parse_expression(&p)
}

@(test)
test_expr_precedence_mul_over_add :: proc(t: ^testing.T) {
	expr, err := parse_expr_text("a + b * c")
	testing.expect_value(t, err, Parse_Error.None)
	add, is_add := expr.(^Binary_Expr)
	testing.expect(t, is_add)
	testing.expect_value(t, add.op.kind, Token_Kind.Plus)
	mul, rhs_is_mul := add.rhs.(^Binary_Expr)
	testing.expect(t, rhs_is_mul)
	testing.expect_value(t, mul.op.kind, Token_Kind.Star)
}

@(test)
test_expr_equality_binds_loosest_glyph :: proc(t: ^testing.T) {
	expr, err := parse_expr_text("1.0 + 2.0 == 3.0")
	testing.expect_value(t, err, Parse_Error.None)
	eq, is_eq := expr.(^Binary_Expr)
	testing.expect(t, is_eq)
	testing.expect_value(t, eq.op.kind, Token_Kind.Eq_Eq)
	_, lhs_is_add := eq.lhs.(^Binary_Expr)
	testing.expect(t, lhs_is_add)
}

@(test)
test_expr_word_logic_ladder :: proc(t: ^testing.T) {
	// `or` binds looser than `and` (spec §02), so the and-arm nests.
	expr, err := parse_expr_text("a or b and c")
	testing.expect_value(t, err, Parse_Error.None)
	or_node, is_or := expr.(^Binary_Expr)
	testing.expect(t, is_or)
	testing.expect_value(t, or_node.op.text, "or")
	and_node, rhs_is_and := or_node.rhs.(^Binary_Expr)
	testing.expect(t, rhs_is_and)
	testing.expect_value(t, and_node.op.text, "and")
}

@(test)
test_expr_left_associative_subtraction :: proc(t: ^testing.T) {
	// (a - b) - c, never a - (b - c): the fold direction §10 depends on.
	expr, err := parse_expr_text("a - b - c")
	testing.expect_value(t, err, Parse_Error.None)
	outer, is_bin := expr.(^Binary_Expr)
	testing.expect(t, is_bin)
	_, lhs_is_bin := outer.lhs.(^Binary_Expr)
	testing.expect(t, lhs_is_bin)
	rhs_name, rhs_is_name := outer.rhs.(^Name_Expr)
	testing.expect(t, rhs_is_name)
	testing.expect_value(t, rhs_name.name, "c")
}

@(test)
test_expr_grouping_overrides_precedence :: proc(t: ^testing.T) {
	expr, err := parse_expr_text("(1.0 + 2.0) * 3.0")
	testing.expect_value(t, err, Parse_Error.None)
	mul, is_mul := expr.(^Binary_Expr)
	testing.expect(t, is_mul)
	testing.expect_value(t, mul.op.kind, Token_Kind.Star)
	_, lhs_is_add := mul.lhs.(^Binary_Expr)
	testing.expect(t, lhs_is_add)
}

@(test)
test_expr_call_with_args :: proc(t: ^testing.T) {
	expr, err := parse_expr_text("clamp(5.0, 0.0, 3.0)")
	testing.expect_value(t, err, Parse_Error.None)
	call, is_call := expr.(^Call_Expr)
	testing.expect(t, is_call)
	testing.expect_value(t, len(call.args), 3)
	callee, callee_is_name := call.callee.(^Name_Expr)
	testing.expect(t, callee_is_name)
	testing.expect_value(t, callee.name, "clamp")
}

@(test)
test_expr_ufcs_member_chain :: proc(t: ^testing.T) {
	expr, err := parse_expr_text("a.slerp(b, 0.0)")
	testing.expect_value(t, err, Parse_Error.None)
	call, is_call := expr.(^Call_Expr)
	testing.expect(t, is_call)
	testing.expect_value(t, len(call.args), 2)
	member, callee_is_member := call.callee.(^Member_Expr)
	testing.expect(t, callee_is_member)
	testing.expect_value(t, member.member, "slerp")
}

@(test)
test_expr_type_associated_constant :: proc(t: ^testing.T) {
	expr, err := parse_expr_text("Fixed.MAX")
	testing.expect_value(t, err, Parse_Error.None)
	member, is_member := expr.(^Member_Expr)
	testing.expect(t, is_member)
	testing.expect_value(t, member.member, "MAX")
	recv, recv_is_name := member.receiver.(^Name_Expr)
	testing.expect(t, recv_is_name)
	testing.expect_value(t, recv.name, "Fixed")
}

@(test)
test_expr_type_associated_call_chain :: proc(t: ^testing.T) {
	expr, err := parse_expr_text("Quat.identity.rotate(v)")
	testing.expect_value(t, err, Parse_Error.None)
	call, is_call := expr.(^Call_Expr)
	testing.expect(t, is_call)
	rotate, callee_is_member := call.callee.(^Member_Expr)
	testing.expect(t, callee_is_member)
	testing.expect_value(t, rotate.member, "rotate")
	_, recv_is_member := rotate.receiver.(^Member_Expr)
	testing.expect(t, recv_is_member)
}

@(test)
test_expr_variant_with_payload :: proc(t: ^testing.T) {
	expr, err := parse_expr_text("Option::Some(3.0)")
	testing.expect_value(t, err, Parse_Error.None)
	variant, is_variant := expr.(^Variant_Expr)
	testing.expect(t, is_variant)
	testing.expect_value(t, variant.type_name, "Option")
	testing.expect_value(t, variant.variant, "Some")
	testing.expect(t, variant.has_payload)
	testing.expect_value(t, len(variant.payload), 1)
}

@(test)
test_expr_variant_without_payload :: proc(t: ^testing.T) {
	expr, err := parse_expr_text("Option::None")
	testing.expect_value(t, err, Parse_Error.None)
	variant, is_variant := expr.(^Variant_Expr)
	testing.expect(t, is_variant)
	testing.expect_value(t, variant.variant, "None")
	testing.expect(t, !variant.has_payload)
}

@(test)
test_expr_record_literal :: proc(t: ^testing.T) {
	expr, err := parse_expr_text("Vec2{x: 3.0, y: 4.0}")
	testing.expect_value(t, err, Parse_Error.None)
	record, is_record := expr.(^Record_Expr)
	testing.expect(t, is_record)
	testing.expect_value(t, record.type_name, "Vec2")
	testing.expect_value(t, len(record.fields), 2)
	testing.expect_value(t, record.fields[1].name, "y")
}

@(test)
test_expr_list_literal :: proc(t: ^testing.T) {
	expr, err := parse_expr_text("[1.0, -1.0]")
	testing.expect_value(t, err, Parse_Error.None)
	list, is_list := expr.(^List_Expr)
	testing.expect(t, is_list)
	testing.expect_value(t, len(list.elements), 2)
	neg, second_is_unary := list.elements[1].(^Unary_Expr)
	testing.expect(t, second_is_unary)
	testing.expect_value(t, neg.op.kind, Token_Kind.Minus)
}

@(test)
test_expr_empty_list :: proc(t: ^testing.T) {
	expr, err := parse_expr_text("[]")
	testing.expect_value(t, err, Parse_Error.None)
	list, is_list := expr.(^List_Expr)
	testing.expect(t, is_list)
	testing.expect_value(t, len(list.elements), 0)
}

@(test)
test_expr_lambda_single_return :: proc(t: ^testing.T) {
	expr, err := parse_expr_text("fn(acc, x) { return acc + x }")
	testing.expect_value(t, err, Parse_Error.None)
	lambda, is_lambda := expr.(^Lambda_Expr)
	testing.expect(t, is_lambda)
	testing.expect_value(t, len(lambda.params), 2)
	testing.expect_value(t, lambda.params[0], "acc")
	body, body_is_binary := lambda.body.(^Binary_Expr)
	testing.expect(t, body_is_binary)
	testing.expect_value(t, body.op.kind, Token_Kind.Plus)
}

@(test)
test_expr_unary_minus_tighter_than_division :: proc(t: ^testing.T) {
	// (-1.0) / 0.0 — unary binds above the multiplicative tier.
	expr, err := parse_expr_text("-1.0 / 0.0")
	testing.expect_value(t, err, Parse_Error.None)
	div, is_div := expr.(^Binary_Expr)
	testing.expect(t, is_div)
	testing.expect_value(t, div.op.kind, Token_Kind.Slash)
	_, lhs_is_unary := div.lhs.(^Unary_Expr)
	testing.expect(t, lhs_is_unary)
}

@(test)
test_expr_not_prefix :: proc(t: ^testing.T) {
	expr, err := parse_expr_text("not a")
	testing.expect_value(t, err, Parse_Error.None)
	unary, is_unary := expr.(^Unary_Expr)
	testing.expect(t, is_unary)
	testing.expect_value(t, unary.op.text, "not")
}

@(test)
test_expr_golden_fold_assert :: proc(t: ^testing.T) {
	// The golden file's densest expression parses to == over the fold
	// call and the saturating subtraction.
	expr, err := parse_expr_text("fold([1.0, -1.0], Fixed.MAX, fn(acc, x) { return acc + x }) == Fixed.MAX - 1.0")
	testing.expect_value(t, err, Parse_Error.None)
	eq, is_eq := expr.(^Binary_Expr)
	testing.expect(t, is_eq)
	testing.expect_value(t, eq.op.kind, Token_Kind.Eq_Eq)
	call, lhs_is_call := eq.lhs.(^Call_Expr)
	testing.expect(t, lhs_is_call)
	testing.expect_value(t, len(call.args), 3)
	sub, rhs_is_sub := eq.rhs.(^Binary_Expr)
	testing.expect(t, rhs_is_sub)
	testing.expect_value(t, sub.op.kind, Token_Kind.Minus)
}

@(test)
test_expr_index_form_is_rejected :: proc(t: ^testing.T) {
	// xs[i] is not part of the expression grammar (spec §02: list access
	// is the total xs.get(i)); a bracket after a name ends the
	// expression, so the statement fails to terminate.
	tokens := stage_lex("test \"x\" {\nassert xs[0] == 1.0\n}\n")
	_, err := stage_parse(tokens)
	testing.expect_value(t, err, Parse_Error.Unexpected_Token)
}
