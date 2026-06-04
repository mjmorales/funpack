// Typecheck for the evaluable domain: a recursive expr_check mirrors
// what the evaluator computes and gates everything else out as
// Unsupported_Expr, so a counted assert never reaches a form the
// kernel cannot produce bits for. There is no implicit promotion
// (spec §10) — equality and arithmetic demand same-typed sides, and
// the Int → Fixed lift is the explicit to_fixed call. Full static name
// resolution widens this behind the same stage seam.
package funpack

Value_Type :: enum {
	Int,
	Fixed,
	Bool,
	Option, // opaque here — payload types are the full checker's seam
}

Type_Error :: enum {
	None,
	Assert_Not_Bool,  // an assert whose expression is not Bool-typed
	Type_Mismatch,    // differently-typed sides — no implicit promotion
	Unsupported_Expr, // a parsed form outside the evaluable domain
}

stage_typecheck :: proc(ast: Ast) -> (typed: Typed_Ast, err: Type_Error) {
	for test in ast.tests {
		for stmt in test.body {
			// A let binding carries no checkable domain — binding types
			// arrive with the evaluation environment; only asserts are
			// judged here.
			node, is_assert := stmt.(Assert_Node)
			if is_assert {
				check_assert(node) or_return
			}
		}
	}
	return Typed_Ast{ast = ast}, .None
}

check_assert :: proc(node: Assert_Node) -> Type_Error {
	type := expr_check(node.expr) or_return
	if type != .Bool {
		return .Assert_Not_Bool
	}
	return .None
}

expr_check :: proc(expr: Expr) -> (type: Value_Type, err: Type_Error) {
	#partial switch e in expr {
	case ^Int_Lit_Expr:
		return .Int, .None
	case ^Fixed_Lit_Expr:
		return .Fixed, .None
	case ^Unary_Expr:
		if e.op.kind != .Minus {
			return .Int, .Unsupported_Expr
		}
		operand := expr_check(e.operand) or_return
		if operand == .Bool {
			return .Int, .Type_Mismatch
		}
		return operand, .None
	case ^Binary_Expr:
		lhs := expr_check(e.lhs) or_return
		rhs := expr_check(e.rhs) or_return
		if e.op.kind == .Eq_Eq {
			if lhs != rhs {
				return .Int, .Type_Mismatch
			}
			return .Bool, .None
		}
		#partial switch e.op.kind {
		case .Plus, .Minus, .Star, .Slash, .Percent:
			if lhs != rhs || lhs == .Bool {
				return .Int, .Type_Mismatch
			}
			return lhs, .None
		}
		return .Int, .Unsupported_Expr
	case ^Member_Expr:
		recv, is_name := e.receiver.(^Name_Expr)
		if is_name && recv.name == "Fixed" && (e.member == "MAX" || e.member == "MIN") {
			return .Fixed, .None
		}
		return .Int, .Unsupported_Expr
	case ^Call_Expr:
		return call_check(e)
	case ^Variant_Expr:
		if e.type_name != "Option" {
			return .Int, .Unsupported_Expr
		}
		switch e.variant {
		case "Some":
			if !e.has_payload || len(e.payload) != 1 {
				return .Int, .Unsupported_Expr
			}
			expr_check(e.payload[0]) or_return
			return .Option, .None
		case "None":
			if e.has_payload {
				return .Int, .Unsupported_Expr
			}
			return .Option, .None
		}
		return .Int, .Unsupported_Expr
	}
	return .Int, .Unsupported_Expr
}

// call_check types the builtin surface: each name has one signature,
// checked argument by argument with no promotion.
call_check :: proc(e: ^Call_Expr) -> (type: Value_Type, err: Type_Error) {
	name, is_name := e.callee.(^Name_Expr)
	if !is_name {
		return .Int, .Unsupported_Expr
	}
	switch name.name {
	case "to_fixed":
		check_args(e, {.Int}) or_return
		return .Fixed, .None
	case "trunc", "floor", "round":
		check_args(e, {.Fixed}) or_return
		return .Int, .None
	case "clamp", "lerp":
		check_args(e, {.Fixed, .Fixed, .Fixed}) or_return
		return .Fixed, .None
	case "checked_div":
		check_args(e, {.Fixed, .Fixed}) or_return
		return .Option, .None
	}
	return .Int, .Unsupported_Expr
}

check_args :: proc(e: ^Call_Expr, signature: []Value_Type) -> Type_Error {
	if len(e.args) != len(signature) {
		return .Type_Mismatch
	}
	for want, i in signature {
		got, err := expr_check(e.args[i])
		if err != .None {
			return err
		}
		if got != want {
			return .Type_Mismatch
		}
	}
	return .None
}
