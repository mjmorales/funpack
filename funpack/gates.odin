// The structural-gate stage sits between parse and typecheck (spec §01
// P5: budgets are fixed compiler constants, no per-site waiver). It reads
// the pure AST — before any name resolution — and rejects a source that
// overshoots a named compiler budget: cyclomatic complexity, nesting
// depth, function size, parameter arity, match exhaustiveness, or a
// structural duplicate. This file owns the seam and the closed Gate_Error
// taxonomy; stage_gates is the single plug-point for the per-gate checks.
package funpack

// The structural budgets are compiler constants, not configuration: a
// gate verdict must be reproducible from the source alone, with no project
// dial to relax it.
MAX_CYCLOMATIC :: 10
MAX_NESTING_DEPTH :: 3
MAX_FN_STATEMENTS :: 40
MAX_PARAM_ARITY :: 5

// Gate_Error is closed with one dedicated arm per gate family and no
// catch-all: a gate violation names exactly which budget the source
// overshot, never a generic "structural" reject.
Gate_Error :: enum {
	None,
	Cyclomatic_Exceeded,    // a function's branch count exceeds MAX_CYCLOMATIC
	Nesting_Exceeded,       // a block nests deeper than MAX_NESTING_DEPTH
	Fn_Size_Exceeded,       // a function body holds more than MAX_FN_STATEMENTS
	Arity_Exceeded,         // a parameter list is longer than MAX_PARAM_ARITY
	Non_Exhaustive_Match,   // a match leaves a variant of its scrutinee unhandled
	Duplicate_Declaration,  // two declaration units normalize to the same AST hash
}

// stage_gates walks the parsed AST and returns the first budget it
// overshoots.
// TODO: per-gate checks (cyclomatic, nesting, exhaustiveness,
// duplication) plug in here alongside the fn-size and arity gates below;
// each new gate is a self-contained proc plus its own arm in this seam.
stage_gates :: proc(ast: Ast) -> Gate_Error {
	if err := gate_fn_size(ast); err != .None {
		return err
	}
	if err := gate_arity(ast); err != .None {
		return err
	}
	return .None
}

// gate_fn_size rejects a test block whose statement count exceeds
// MAX_FN_STATEMENTS. The Test_Node.body slice is the only
// statement-sequence unit the surface has, so its length is the
// function-size budget.
gate_fn_size :: proc(ast: Ast) -> Gate_Error {
	for test in ast.tests {
		if len(test.body) > MAX_FN_STATEMENTS {
			return .Fn_Size_Exceeded
		}
	}
	return .None
}

// gate_arity rejects a Lambda_Expr whose parameter list exceeds
// MAX_PARAM_ARITY. It walks every statement RHS in every test block and
// every nested expression, so a lambda buried in a call argument or
// another lambda's body is still checked. Running here — before
// stage_typecheck — means an over-arity lambda is a structural Gate_Error,
// not a downstream type mismatch.
gate_arity :: proc(ast: Ast) -> Gate_Error {
	for test in ast.tests {
		for stmt in test.body {
			switch s in stmt {
			case Assert_Node:
				if err := arity_walk_expr(s.expr); err != .None {
					return err
				}
			case Let_Node:
				if err := arity_walk_expr(s.value); err != .None {
					return err
				}
			}
		}
	}
	return .None
}

// arity_walk_expr recurses the whole expression tree, checking each
// Lambda_Expr's param count and descending into every sub-expression that
// can host a nested lambda (call args, member receivers, operands,
// record/list/variant elements, lambda bodies, match scrutinees and arm
// bodies).
arity_walk_expr :: proc(expr: Expr) -> Gate_Error {
	switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^Name_Expr:
		// Leaf atoms host no sub-expressions.
	case ^Call_Expr:
		if err := arity_walk_expr(e.callee); err != .None {
			return err
		}
		for arg in e.args {
			if err := arity_walk_expr(arg); err != .None {
				return err
			}
		}
	case ^Member_Expr:
		return arity_walk_expr(e.receiver)
	case ^Variant_Expr:
		for arg in e.payload {
			if err := arity_walk_expr(arg); err != .None {
				return err
			}
		}
	case ^Record_Expr:
		for field in e.fields {
			if err := arity_walk_expr(field.value); err != .None {
				return err
			}
		}
	case ^List_Expr:
		for element in e.elements {
			if err := arity_walk_expr(element); err != .None {
				return err
			}
		}
	case ^Lambda_Expr:
		if len(e.params) > MAX_PARAM_ARITY {
			return .Arity_Exceeded
		}
		return arity_walk_expr(e.body)
	case ^Unary_Expr:
		return arity_walk_expr(e.operand)
	case ^Binary_Expr:
		if err := arity_walk_expr(e.lhs); err != .None {
			return err
		}
		return arity_walk_expr(e.rhs)
	case ^Match_Expr:
		if err := arity_walk_expr(e.scrutinee); err != .None {
			return err
		}
		for arm in e.arms {
			if err := arity_walk_expr(arm.body); err != .None {
				return err
			}
		}
	}
	return .None
}
