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
	Assert_Not_Bool, // an assert whose expression is not the == form
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
	// assert demands a Bool; the thin expression surface produces one
	// only through ==.
	if !node.expr.is_equal {
		return .Assert_Not_Bool
	}
	if operand_type(node.expr.lhs) != .Fixed || operand_type(node.expr.rhs) != .Fixed {
		return .Assert_Operand_Not_Fixed
	}
	return .None
}

operand_type :: proc(op: Operand) -> Value_Type {
	if op.kind == .Int_Literal {
		return .Int
	}
	// Fixed_Literal is Fixed by form; To_Fixed_Call is Fixed because
	// to_fixed is Int -> Fixed (spec §10 conversion table).
	return .Fixed
}
