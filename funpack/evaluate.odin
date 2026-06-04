// Evaluator for the thin path: equality over Q32.32 bit patterns.
// Fixed is transparent integer data (spec §10), so == is integer
// equality — no epsilon, bit-identical on every machine. The saturating
// arithmetic surface widens this behind the same seam.
package funpack

stage_evaluate :: proc(typed: Typed_Ast) -> Eval_Result {
	result := Eval_Result{}
	for test in typed.ast.tests {
		for node in test.asserts {
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
	return eval_operand(node.lhs) == eval_operand(node.rhs)
}

// eval_operand sees only Fixed-domain operands — the typecheck rejected
// bare Int literals before evaluation.
eval_operand :: proc(op: Operand) -> Fixed {
	if op.kind == .To_Fixed_Call {
		return to_fixed(op.int_value)
	}
	return op.fixed_bits
}
