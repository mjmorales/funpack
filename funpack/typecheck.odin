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
}

stage_typecheck :: proc(ast: Ast) -> (typed: Typed_Ast, err: Type_Error) {
	for test in ast.tests {
		for node in test.asserts {
			check_assert(node) or_return
		}
	}
	return Typed_Ast{ast = ast}, .None
}

check_assert :: proc(node: Assert_Node) -> Type_Error {
	if operand_type(node.lhs) != .Fixed || operand_type(node.rhs) != .Fixed {
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
