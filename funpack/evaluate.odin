// Evaluator for the thin path: equality over Q32.32 bit patterns.
// Fixed is transparent integer data (spec §10), so == is integer
// equality — no epsilon, bit-identical on every machine. The saturating
// arithmetic surface widens this behind the same seam.
package funpack

stage_evaluate :: proc(typed: Typed_Ast) -> Eval_Result {
	result := Eval_Result{}
	for test in typed.ast.tests {
		for stmt in test.body {
			// Only asserts evaluate in the thin layer; a let binding's
			// value is a later seam (its expression is parsed and
			// type-gated, never executed here).
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

eval_assert :: proc(node: Assert_Node) -> bool {
	// The typecheck admitted only the == form over the thin domain.
	bin, is_binary := node.expr.(^Binary_Expr)
	if !is_binary {
		return false
	}
	return eval_expr(bin.lhs) == eval_expr(bin.rhs)
}

// eval_expr sees only the Fixed-domain forms the typecheck admitted:
// Fixed literals and the explicit to_fixed(Int) lift.
eval_expr :: proc(expr: Expr) -> Fixed {
	#partial switch e in expr {
	case ^Fixed_Lit_Expr:
		return e.bits
	case ^Call_Expr:
		arg, is_int := e.args[0].(^Int_Lit_Expr)
		if is_int {
			return to_fixed(arg.value)
		}
	}
	return Fixed(0)
}
