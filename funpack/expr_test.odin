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

@(test)
test_expr_with_update :: proc(t: ^testing.T) {
	// `value with { field: v }` — a record-update expression (spec §02 §5).
	expr, err := parse_expr_text("score with { left: score.left + 1 }")
	testing.expect_value(t, err, Parse_Error.None)
	with, is_with := expr.(^With_Expr)
	testing.expect(t, is_with)
	if !is_with {
		return
	}
	base, base_is_name := with.base.(^Name_Expr)
	testing.expect(t, base_is_name)
	if base_is_name {
		testing.expect_value(t, base.name, "score")
	}
	testing.expect_value(t, len(with.fields), 1)
	testing.expect_value(t, with.fields[0].name, "left")
	_, field_is_binary := with.fields[0].value.(^Binary_Expr)
	testing.expect(t, field_is_binary)
}

@(test)
test_expr_with_binds_tighter_than_unary :: proc(t: ^testing.T) {
	// `with` binds just above unary in the precedence ladder (spec §02 §3:
	// … unary → with → call/member), so a unary minus wraps the whole
	// `self with { … }` rather than only `self`.
	expr, err := parse_expr_text("-self with { y: 1.0 }")
	testing.expect_value(t, err, Parse_Error.None)
	unary, is_unary := expr.(^Unary_Expr)
	testing.expect(t, is_unary)
	if is_unary {
		_, operand_is_with := unary.operand.(^With_Expr)
		testing.expect(t, operand_is_with)
	}
}

@(test)
test_expr_struct_payload_variant :: proc(t: ^testing.T) {
	// A struct-payload variant `Draw::Rect{ at: …, size: … }` (spec §03 §2):
	// the `::` selector then a named-field body.
	expr, err := parse_expr_text("Draw::Rect{at: Vec2{x: 1.0, y: 2.0}, color: Color::White}")
	testing.expect_value(t, err, Parse_Error.None)
	variant, is_variant := expr.(^Variant_Expr)
	testing.expect(t, is_variant)
	if !is_variant {
		return
	}
	testing.expect_value(t, variant.type_name, "Draw")
	testing.expect_value(t, variant.variant, "Rect")
	testing.expect(t, variant.has_fields)
	testing.expect(t, !variant.has_payload)
	testing.expect_value(t, len(variant.fields), 2)
	testing.expect_value(t, variant.fields[0].name, "at")
	testing.expect_value(t, variant.fields[1].name, "color")
}

@(test)
test_expr_tuple_payload_command_wrap :: proc(t: ^testing.T) {
	// The tuple-payload command-wrap `Spawn( Paddle{…} )` (spec §02 §2,
	// fun.ll1.md §5A): an UpperCamel callee applied to a single thing-literal
	// argument — parsed as a Call_Expr, the command-wrap-is-call shape.
	expr, err := parse_expr_text("Spawn( Ball{pos: Vec2{x: 1.0, y: 2.0}} )")
	testing.expect_value(t, err, Parse_Error.None)
	call, is_call := expr.(^Call_Expr)
	testing.expect(t, is_call)
	if !is_call {
		return
	}
	callee, callee_is_name := call.callee.(^Name_Expr)
	testing.expect(t, callee_is_name)
	if callee_is_name {
		testing.expect_value(t, callee.name, "Spawn")
	}
	testing.expect_value(t, len(call.args), 1)
	_, arg_is_record := call.args[0].(^Record_Expr)
	testing.expect(t, arg_is_record)
}

@(test)
test_expr_variant_tuple_payload :: proc(t: ^testing.T) {
	// A tuple-payload enum variant via `::` — Option::Some(Side::Right) —
	// nests a bare variant inside the payload (spec §03 §2).
	expr, err := parse_expr_text("Option::Some(Side::Right)")
	testing.expect_value(t, err, Parse_Error.None)
	variant, is_variant := expr.(^Variant_Expr)
	testing.expect(t, is_variant)
	if !is_variant {
		return
	}
	testing.expect(t, variant.has_payload)
	testing.expect(t, !variant.has_fields)
	testing.expect_value(t, len(variant.payload), 1)
	inner, inner_is_variant := variant.payload[0].(^Variant_Expr)
	testing.expect(t, inner_is_variant)
	if inner_is_variant {
		testing.expect_value(t, inner.variant, "Right")
	}
}

@(test)
test_expr_string_interpolation_literal :: proc(t: ^testing.T) {
	// A string-interpolation literal `"{self.left}   {self.right}"` parses to
	// a String_Lit_Expr that retains its raw inner text, holes included
	// (spec §02 §2 — the split is a later concern, not grammar).
	expr, err := parse_expr_text("\"{self.left}   {self.right}\"")
	testing.expect_value(t, err, Parse_Error.None)
	str, is_str := expr.(^String_Lit_Expr)
	testing.expect(t, is_str)
	if is_str {
		testing.expect_value(t, str.text, "{self.left}   {self.right}")
	}
}

@(test)
test_expr_chained_with_updates :: proc(t: ^testing.T) {
	// `with` nests left-to-right (spec §02 §5): `a with {…} with {…}` wraps
	// the first update as the base of the second.
	expr, err := parse_expr_text("self with { x: 1.0 } with { y: 2.0 }")
	testing.expect_value(t, err, Parse_Error.None)
	outer, is_with := expr.(^With_Expr)
	testing.expect(t, is_with)
	if is_with {
		_, base_is_with := outer.base.(^With_Expr)
		testing.expect(t, base_is_with)
		testing.expect_value(t, outer.fields[0].name, "y")
	}
}

@(test)
test_expr_tuple_literal :: proc(t: ^testing.T) {
	// The snake return value `(rng, [Spawn(...)])` (spec §02; §04 §1): a
	// parenthesized comma-list parses to a Tuple_Expr with one element per
	// position, in source order.
	expr, err := parse_expr_text("(next, [Spawn(food)])")
	testing.expect_value(t, err, Parse_Error.None)
	tup, is_tuple := expr.(^Tuple_Expr)
	testing.expect(t, is_tuple)
	if is_tuple {
		testing.expect_value(t, len(tup.elements), 2)
		first, first_is_name := tup.elements[0].(^Name_Expr)
		testing.expect(t, first_is_name)
		if first_is_name {
			testing.expect_value(t, first.name, "next")
		}
		_, second_is_list := tup.elements[1].(^List_Expr)
		testing.expect(t, second_is_list)
	}
}

@(test)
test_expr_single_paren_is_grouping_not_tuple :: proc(t: ^testing.T) {
	// A single parenthesized expression with no comma stays a grouping — it
	// unwraps to its inner expression, NOT a 1-tuple (the comma is the
	// discriminator, spec §02).
	expr, err := parse_expr_text("(rng)")
	testing.expect_value(t, err, Parse_Error.None)
	_, is_tuple := expr.(^Tuple_Expr)
	testing.expect(t, !is_tuple)
	name, is_name := expr.(^Name_Expr)
	testing.expect(t, is_name)
	if is_name {
		testing.expect_value(t, name.name, "rng")
	}
}

@(test)
test_expr_tuple_trailing_comma :: proc(t: ^testing.T) {
	// A trailing comma after the last tuple element is accepted, mirroring
	// lists — `(a, b,)` is the same two-element tuple as `(a, b)`.
	expr, err := parse_expr_text("(a, b,)")
	testing.expect_value(t, err, Parse_Error.None)
	tup, is_tuple := expr.(^Tuple_Expr)
	testing.expect(t, is_tuple)
	if is_tuple {
		testing.expect_value(t, len(tup.elements), 2)
	}
}

@(test)
test_expr_tuple_pattern_with_nested_variant :: proc(t: ^testing.T) {
	// The snake `match pick(free, rng) { (Option::Some(cell), next) => … }`
	// shape (spec §02 §5): a tuple pattern whose first position is a
	// variant-with-binder sub-pattern and whose second is a bare binder.
	source := "match picked {\n" +
		"  (Option::Some(cell), next) => cell\n" +
		"  (Option::None, next) => next\n" +
		"}\n"
	expr, err := parse_expr_text(source)
	testing.expect_value(t, err, Parse_Error.None)
	m, is_match := expr.(^Match_Expr)
	testing.expect(t, is_match)
	if !is_match {
		return
	}
	testing.expect_value(t, len(m.arms), 2)
	// First arm's pattern is a 2-element tuple: a Variant_Binds then a Bare_Binder.
	first := m.arms[0].pattern
	testing.expect_value(t, first.kind, Pattern_Kind.Tuple)
	testing.expect_value(t, len(first.elements), 2)
	testing.expect_value(t, first.elements[0].kind, Pattern_Kind.Variant_Binds)
	testing.expect_value(t, first.elements[0].type_name, "Option")
	testing.expect_value(t, first.elements[0].variant, "Some")
	testing.expect_value(t, len(first.elements[0].binders), 1)
	testing.expect_value(t, first.elements[0].binders[0], "cell")
	testing.expect_value(t, first.elements[1].kind, Pattern_Kind.Bare_Binder)
	testing.expect_value(t, len(first.elements[1].binders), 1)
	testing.expect_value(t, first.elements[1].binders[0], "next")
	// Second arm's first position is a bare variant (no payload binders).
	second := m.arms[1].pattern
	testing.expect_value(t, second.kind, Pattern_Kind.Tuple)
	testing.expect_value(t, second.elements[0].kind, Pattern_Kind.Bare_Variant)
	testing.expect_value(t, second.elements[0].variant, "None")
}
