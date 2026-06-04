// Typecheck for the thin path: an assert's == must compare within the
// Fixed domain. There is no implicit Int → Fixed promotion (spec §10) —
// a bare Int operand against a Fixed operand is a type error, and the
// lift is the explicit to_fixed call. Full name resolution widens this
// behind the same stage seam.
package funpack

Value_Type :: enum {
	Int,
	Fixed,
}

Type_Error :: enum {
	None,
	Assert_Operand_Not_Fixed,
	Assert_Not_Bool,  // an assert whose expression is not the == form
	Unsupported_Expr, // a parsed form outside the thin evaluation domain
}

stage_typecheck :: proc(ast: Ast) -> (typed: Typed_Ast, err: Type_Error) {
	for test in ast.tests {
		for stmt in test.body {
			// A let binding carries no checkable domain in the thin
			// layer — name resolution and binding types are later seams;
			// only asserts are judged here.
			node, is_assert := stmt.(Assert_Node)
			if is_assert {
				check_assert(node) or_return
			}
		}
	}
	return Typed_Ast{ast = ast}, .None
}

check_assert :: proc(node: Assert_Node) -> Type_Error {
	// assert demands a Bool; the thin evaluation domain produces one
	// only through ==.
	bin, is_binary := node.expr.(^Binary_Expr)
	if !is_binary || bin.op.kind != .Eq_Eq {
		return .Assert_Not_Bool
	}
	lhs_type, lhs_ok := expr_type(bin.lhs)
	rhs_type, rhs_ok := expr_type(bin.rhs)
	if !lhs_ok || !rhs_ok {
		return .Unsupported_Expr
	}
	if lhs_type != .Fixed || rhs_type != .Fixed {
		return .Assert_Operand_Not_Fixed
	}
	return .None
}

// expr_type judges the thin evaluation domain: literals and the
// explicit to_fixed lift. Every other parsed form is structurally
// valid but not yet evaluable — rejected honestly (ok = false) rather
// than silently passed through; the numeric kernel widens this domain
// behind the same seam.
expr_type :: proc(expr: Expr) -> (type: Value_Type, ok: bool) {
	#partial switch e in expr {
	case ^Int_Lit_Expr:
		return .Int, true
	case ^Fixed_Lit_Expr:
		return .Fixed, true
	case ^Call_Expr:
		// to_fixed is Int -> Fixed (spec §10 conversion table).
		name, is_name := e.callee.(^Name_Expr)
		if is_name && name.name == "to_fixed" && len(e.args) == 1 {
			arg_type, arg_ok := expr_type(e.args[0])
			if arg_ok && arg_type == .Int {
				return .Fixed, true
			}
		}
	}
	return .Int, false
}
