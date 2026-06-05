// The structural-gate stage sits between parse and typecheck (spec §02:
// one shape, one budget). It reads the pure AST — before any name
// resolution — and rejects a source that overshoots a named compiler
// budget: cyclomatic complexity, nesting depth, function size, parameter
// arity, match exhaustiveness, or a duplicate declaration. Each budget is
// a fixed compiler constant with no config surface and no waiver, so a
// gate verdict is reproducible from the source alone. This stage owns the
// seam and the closed Gate_Error taxonomy; every individual check lands as
// its own sibling story, so the body here is pass-through.
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
	Duplicate_Declaration,  // a name is declared twice in one scope
}

// stage_gates walks the parsed AST and returns the first budget it
// overshoots. The individual checks are sibling stories; this body is the
// pass-through seam.
stage_gates :: proc(ast: Ast) -> Gate_Error {
	return .None
}
