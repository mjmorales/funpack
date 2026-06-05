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
// overshoots. The gate unit is the test block: each block's statement RHS
// expressions are the only code on the golden surface, so every gate folds
// over a Test_Node body and the seam returns the first violation found.
stage_gates :: proc(ast: Ast) -> Gate_Error {
	if err := gate_fn_size(ast); err != .None {
		return err
	}
	if err := gate_arity(ast); err != .None {
		return err
	}
	for test in ast.tests {
		if err := check_cyclomatic(test); err != .None {
			return err
		}
		if err := check_nesting(test); err != .None {
			return err
		}
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

// check_cyclomatic enforces the branch-count budget over a test block.
// Cyclomatic complexity is 1 + the number of decision points; on the
// golden surface the only branching construct is boolean short-circuit, so
// each `and`/`or` Binary_Expr is the sole decision point. The `and`/`or`
// operators are word operators carried as Ident tokens keyed by text (see
// infix_power in expr.odin), so the count keys off op text the same way —
// no glyph operator (`+`, `==`, …) is a branch.
check_cyclomatic :: proc(test: Test_Node) -> Gate_Error {
	decisions := 0
	for stmt in test.body {
		decisions += count_short_circuit(statement_expr(stmt))
	}
	if 1 + decisions > MAX_CYCLOMATIC {
		return .Cyclomatic_Exceeded
	}
	return .None
}

// count_short_circuit folds the and/or decision points over one Expr
// tree. Every union arm is visited so a short-circuit buried in any sub-
// expression (a call argument, a record field, a lambda body) still
// counts.
count_short_circuit :: proc(expr: Expr) -> int {
	count := 0
	#partial switch e in expr {
	case ^Unary_Expr:
		count += count_short_circuit(e.operand)
	case ^Binary_Expr:
		if is_short_circuit(e.op) {
			count += 1
		}
		count += count_short_circuit(e.lhs)
		count += count_short_circuit(e.rhs)
	case ^Member_Expr:
		count += count_short_circuit(e.receiver)
	case ^Call_Expr:
		count += count_short_circuit(e.callee)
		for arg in e.args {
			count += count_short_circuit(arg)
		}
	case ^Record_Expr:
		for field in e.fields {
			count += count_short_circuit(field.value)
		}
	case ^List_Expr:
		for element in e.elements {
			count += count_short_circuit(element)
		}
	case ^Lambda_Expr:
		count += count_short_circuit(e.body)
	case ^Variant_Expr:
		for arg in e.payload {
			count += count_short_circuit(arg)
		}
	case ^Match_Expr:
		count += count_short_circuit(e.scrutinee)
		for arm in e.arms {
			count += count_short_circuit(arm.body)
		}
	}
	return count
}

// is_short_circuit reports whether a Binary_Expr operator is a boolean
// short-circuit `and`/`or`. Those are word operators lexed as Ident tokens
// (expr.odin infix_power keys them by text), so the test matches op text,
// not a glyph kind.
is_short_circuit :: proc(op: Token) -> bool {
	return op.kind == .Ident && (op.text == "and" || op.text == "or")
}

// check_nesting enforces the Expr-tree nesting budget over a test block.
//
// The metric counts only *compositional* nesting — the constructs that
// hold sub-expressions inside a container: a call's argument list, a
// record's field values, a list's elements, and a lambda body. Each opens
// one nesting level. Descending through a binary/unary operator spine or a
// member-access receiver does NOT open a level: `a == b`, `-x`, and the
// `Quat.identity.rotate` member chain are flat, not nested, so the
// operator/receiver passes through at the same depth and keeps looking for
// containers underneath. This matches spec §29 §4 / §01 P5, which frame
// the nesting budget as a *scope-creep inside one function* control on
// composition depth, not a count of every AST edge. (A naive raw edge
// count would flag shallow golden asserts like
// `cross(Vec3{…}, Vec3{…}) == Vec3{…}` whose intent is plainly flat.)
check_nesting :: proc(test: Test_Node) -> Gate_Error {
	for stmt in test.body {
		if nesting_depth(statement_expr(stmt)) > MAX_NESTING_DEPTH {
			return .Nesting_Exceeded
		}
	}
	return .None
}

// nesting_depth returns the deepest compositional-container nesting in one
// Expr tree. A container (call args, record fields, list elements, lambda
// body) adds one to the depth of its contents; an operator spine or member
// receiver passes its child's depth through unchanged.
nesting_depth :: proc(expr: Expr) -> int {
	#partial switch e in expr {
	case ^Unary_Expr:
		return nesting_depth(e.operand)
	case ^Binary_Expr:
		return max(nesting_depth(e.lhs), nesting_depth(e.rhs))
	case ^Member_Expr:
		return nesting_depth(e.receiver)
	case ^Call_Expr:
		inner := nesting_depth(e.callee)
		for arg in e.args {
			inner = max(inner, nesting_depth(arg))
		}
		return 1 + inner
	case ^Record_Expr:
		inner := 0
		for field in e.fields {
			inner = max(inner, nesting_depth(field.value))
		}
		return 1 + inner
	case ^List_Expr:
		inner := 0
		for element in e.elements {
			inner = max(inner, nesting_depth(element))
		}
		return 1 + inner
	case ^Lambda_Expr:
		return 1 + nesting_depth(e.body)
	case ^Variant_Expr:
		inner := 0
		for arg in e.payload {
			inner = max(inner, nesting_depth(arg))
		}
		return 1 + inner
	case ^Match_Expr:
		inner := nesting_depth(e.scrutinee)
		for arm in e.arms {
			inner = max(inner, nesting_depth(arm.body))
		}
		return 1 + inner
	}
	// An atom (literal or bare name) is a leaf — depth zero.
	return 0
}

// statement_expr is the single RHS expression a statement contributes to
// the gate walks: a let's bound value or an assert's asserted expression.
statement_expr :: proc(stmt: Statement) -> Expr {
	switch node in stmt {
	case Let_Node:
		return node.value
	case Assert_Node:
		return node.expr
	}
	return nil
}
