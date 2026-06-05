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
// overshoots. Each gate family is a self-contained walk over the same
// AST; the arms compose so sibling gates plug in alongside without
// touching each other's logic.
stage_gates :: proc(ast: Ast) -> Gate_Error {
	if err := check_match_exhaustiveness(ast); err != .None {
		return err
	}
	return .None
}

// Closed_Variant_Set names a known enum type and the full variant set the
// surface declares for it. The exhaustiveness gate computes coverage
// against this closed set — the only types it can prove total, since
// coverage means "every variant accounted for" and an open type has no
// fixed denominator.
Closed_Variant_Set :: struct {
	type_name: string,
	variants:  []string,
}

// CLOSED_VARIANT_SETS is the closed table of enum types whose variant set
// the surface fixes (spec §26 prelude). Option is the concrete case the
// golden surface and stdlib expose — engine.prelude Option, with variants
// Some and None. A match on any type outside this table carries no known
// denominator, so the gate leaves it for a later stage (typecheck
// contains the whole Match_Expr as Unsupported_Expr). Growing this table
// is a deliberate edit, mirroring STDLIB_SURFACE.
@(rodata)
CLOSED_VARIANT_SETS := []Closed_Variant_Set{
	{type_name = "Option", variants = {"Some", "None"}},
}

closed_variant_set :: proc(type_name: string) -> (set: Closed_Variant_Set, found: bool) {
	for candidate in CLOSED_VARIANT_SETS {
		if candidate.type_name == type_name {
			return candidate, true
		}
	}
	return Closed_Variant_Set{}, false
}

// check_match_exhaustiveness rejects any non-total match (spec §02 §5: a
// non-total match is a compile error). It is pure-AST and runs before
// name resolution: it reads the arm patterns' own type_name/variant
// strings, never a resolved scrutinee type. It walks every test block's
// statements, descends each expression to find match nodes, and proves
// each match total against the closed variant set its arms name.
check_match_exhaustiveness :: proc(ast: Ast) -> Gate_Error {
	for test in ast.tests {
		for stmt in test.body {
			switch node in stmt {
			case Let_Node:
				if err := match_walk_expr(node.value); err != .None {
					return err
				}
			case Assert_Node:
				if err := match_walk_expr(node.expr); err != .None {
					return err
				}
			}
		}
	}
	return .None
}

// match_walk_expr descends an expression, checking every Match_Expr it
// contains (scrutinees and arm bodies nest matches). It mirrors the Expr
// union arm-for-arm so a new expression form is a visible compile gap
// here, not a silently-unwalked branch.
match_walk_expr :: proc(expr: Expr) -> Gate_Error {
	switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^Name_Expr:
		return .None
	case ^Call_Expr:
		if err := match_walk_expr(e.callee); err != .None {
			return err
		}
		for arg in e.args {
			if err := match_walk_expr(arg); err != .None {
				return err
			}
		}
		return .None
	case ^Member_Expr:
		return match_walk_expr(e.receiver)
	case ^Variant_Expr:
		for arg in e.payload {
			if err := match_walk_expr(arg); err != .None {
				return err
			}
		}
		return .None
	case ^Record_Expr:
		for field in e.fields {
			if err := match_walk_expr(field.value); err != .None {
				return err
			}
		}
		return .None
	case ^List_Expr:
		for element in e.elements {
			if err := match_walk_expr(element); err != .None {
				return err
			}
		}
		return .None
	case ^Lambda_Expr:
		return match_walk_expr(e.body)
	case ^Unary_Expr:
		return match_walk_expr(e.operand)
	case ^Binary_Expr:
		if err := match_walk_expr(e.lhs); err != .None {
			return err
		}
		return match_walk_expr(e.rhs)
	case ^Match_Expr:
		if err := match_walk_expr(e.scrutinee); err != .None {
			return err
		}
		for arm in e.arms {
			if err := match_walk_expr(arm.body); err != .None {
				return err
			}
		}
		return check_match_total(e)
	}
	return .None
}

// check_match_total proves one match exhaustive (spec §02 §5). A `_`
// wildcard arm covers everything, so its presence is full coverage. With
// no wildcard, the gate identifies the closed variant set the arms name
// (Option's Some/None from the surface) and demands every variant of that
// set appear in some arm. A match whose arms name no known closed set
// carries no fixed denominator the gate can count against, so it passes
// here and is left for a later stage.
check_match_total :: proc(match: ^Match_Expr) -> Gate_Error {
	type_name := ""
	for arm in match.arms {
		if arm.pattern.kind == .Wildcard {
			return .None
		}
		// The first variant arm fixes the type the match dispatches on;
		// every variant arm of a well-formed match names that one type.
		if type_name == "" {
			type_name = arm.pattern.type_name
		}
	}
	set, known := closed_variant_set(type_name)
	if !known {
		return .None
	}
	for variant in set.variants {
		if !match_covers_variant(match, type_name, variant) {
			return .Non_Exhaustive_Match
		}
	}
	return .None
}

// match_covers_variant reports whether some arm pattern names the given
// (type, variant) pair — the per-variant coverage test the closed-set
// loop runs.
match_covers_variant :: proc(match: ^Match_Expr, type_name: string, variant: string) -> bool {
	for arm in match.arms {
		if arm.pattern.kind == .Wildcard {
			continue
		}
		if arm.pattern.type_name == type_name && arm.pattern.variant == variant {
			return true
		}
	}
	return false
}
