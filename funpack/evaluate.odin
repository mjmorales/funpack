// Evaluator over tagged Values and the saturating scalar kernel.
// Every operation is total and all-integer (spec §10) — no epsilon, no
// float, bit-identical on every machine. eval_expr fails closed: a form
// outside the evaluable domain returns ok = false, and the typecheck
// gate keeps such forms from reaching a counted assert.
package funpack

stage_evaluate :: proc(typed: Typed_Ast) -> Eval_Result {
	result := Eval_Result{}
	for test in typed.ast.tests {
		for stmt in test.body {
			// Only asserts evaluate; a let binding's execution arrives
			// with the evaluation environment behind the same seam.
			node, is_assert := stmt.(Assert_Node)
			if !is_assert {
				continue
			}
			if eval_assert(node) {
				result.passed += 1
			} else {
				result.failed += 1
			}
		}
	}
	return result
}

// eval_assert passes only when the expression evaluates to Bool true.
eval_assert :: proc(node: Assert_Node) -> bool {
	value, ok := eval_expr(node.expr)
	if !ok {
		return false
	}
	passed, is_bool := value.(bool)
	return is_bool && passed
}

eval_expr :: proc(expr: Expr) -> (value: Value, ok: bool) {
	#partial switch e in expr {
	case ^Int_Lit_Expr:
		return e.value, true
	case ^Fixed_Lit_Expr:
		return e.bits, true
	case ^Unary_Expr:
		return eval_unary(e)
	case ^Binary_Expr:
		return eval_binary(e)
	case ^Member_Expr:
		return eval_member(e)
	case ^Call_Expr:
		return eval_call(e)
	case ^Variant_Expr:
		return eval_variant(e)
	}
	return nil, false
}

// eval_variant lowers Option::Some/None — the one variant family in
// the evaluable domain.
eval_variant :: proc(e: ^Variant_Expr) -> (value: Value, ok: bool) {
	if e.type_name != "Option" {
		return nil, false
	}
	switch e.variant {
	case "Some":
		if !e.has_payload || len(e.payload) != 1 {
			return nil, false
		}
		inner := eval_expr(e.payload[0]) or_return
		boxed := new(Value, context.temp_allocator)
		boxed^ = inner
		return Option_Value{is_some = true, payload = boxed}, true
	case "None":
		if e.has_payload {
			return nil, false
		}
		return Option_Value{is_some = false, payload = nil}, true
	}
	return nil, false
}

eval_unary :: proc(e: ^Unary_Expr) -> (value: Value, ok: bool) {
	if e.op.kind != .Minus {
		return nil, false
	}
	operand := eval_expr(e.operand) or_return
	#partial switch v in operand {
	case Fixed:
		return fixed_neg(v), true
	case i64:
		return int_neg(v), true
	}
	return nil, false
}

eval_binary :: proc(e: ^Binary_Expr) -> (value: Value, ok: bool) {
	lhs := eval_expr(e.lhs) or_return
	rhs := eval_expr(e.rhs) or_return
	if e.op.kind == .Eq_Eq {
		return value_equal(lhs, rhs), true
	}
	#partial switch l in lhs {
	case Fixed:
		r, is_fixed := rhs.(Fixed)
		if !is_fixed {
			return nil, false
		}
		#partial switch e.op.kind {
		case .Plus:
			return fixed_add(l, r), true
		case .Minus:
			return fixed_sub(l, r), true
		case .Star:
			return fixed_mul(l, r), true
		case .Slash:
			return fixed_div(l, r), true
		case .Percent:
			return fixed_mod(l, r), true
		}
	case i64:
		r, is_int := rhs.(i64)
		if !is_int {
			return nil, false
		}
		#partial switch e.op.kind {
		case .Plus:
			return int_add(l, r), true
		case .Minus:
			return int_sub(l, r), true
		case .Star:
			return int_mul(l, r), true
		case .Slash:
			return int_div(l, r), true
		case .Percent:
			return int_mod(l, r), true
		}
	}
	return nil, false
}

// eval_member resolves a type's associated constants — the evaluable
// member surface is exactly Fixed.MAX / Fixed.MIN.
eval_member :: proc(e: ^Member_Expr) -> (value: Value, ok: bool) {
	recv, is_name := e.receiver.(^Name_Expr)
	if !is_name {
		return nil, false
	}
	if recv.name == "Fixed" {
		switch e.member {
		case "MAX":
			return FIXED_MAX, true
		case "MIN":
			return FIXED_MIN, true
		}
	}
	return nil, false
}

eval_call :: proc(e: ^Call_Expr) -> (value: Value, ok: bool) {
	name, is_name := e.callee.(^Name_Expr)
	if !is_name {
		return nil, false
	}
	switch name.name {
	case "to_fixed":
		if len(e.args) != 1 {
			return nil, false
		}
		arg := eval_expr(e.args[0]) or_return
		n, is_int := arg.(i64)
		if !is_int {
			return nil, false
		}
		return to_fixed(n), true
	case "trunc":
		f := eval_fixed_arg(e, 0, 1) or_return
		return fixed_trunc(f), true
	case "floor":
		f := eval_fixed_arg(e, 0, 1) or_return
		return fixed_floor(f), true
	case "round":
		f := eval_fixed_arg(e, 0, 1) or_return
		return fixed_round(f), true
	case "clamp":
		x := eval_fixed_arg(e, 0, 3) or_return
		lo := eval_fixed_arg(e, 1, 3) or_return
		hi := eval_fixed_arg(e, 2, 3) or_return
		return fixed_clamp(x, lo, hi), true
	case "lerp":
		a := eval_fixed_arg(e, 0, 3) or_return
		b := eval_fixed_arg(e, 1, 3) or_return
		t := eval_fixed_arg(e, 2, 3) or_return
		return fixed_lerp(a, b, t), true
	case "checked_div":
		a := eval_fixed_arg(e, 0, 2) or_return
		b := eval_fixed_arg(e, 1, 2) or_return
		quotient, has_quotient := fixed_checked_div(a, b)
		if !has_quotient {
			return Option_Value{is_some = false, payload = nil}, true
		}
		boxed := new(Value, context.temp_allocator)
		boxed^ = quotient
		return Option_Value{is_some = true, payload = boxed}, true
	}
	return nil, false
}

// eval_fixed_arg evaluates argument i of an expected-arity call and
// demands a Fixed — the shared shape of the scalar-surface builtins.
eval_fixed_arg :: proc(e: ^Call_Expr, i: int, arity: int) -> (f: Fixed, ok: bool) {
	if len(e.args) != arity {
		return Fixed(0), false
	}
	value := eval_expr(e.args[i]) or_return
	return value.(Fixed)
}
