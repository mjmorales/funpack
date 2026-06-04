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
	}
	return nil, false
}
