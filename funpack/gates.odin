// The structural-gate stage sits between parse and typecheck (spec §01
// P5: budgets are fixed compiler constants, no per-site waiver). It reads
// the pure AST — before any name resolution — and rejects a source that
// overshoots a named compiler budget: cyclomatic complexity, nesting
// depth, function size, parameter arity, match exhaustiveness, or a
// structural duplicate. This file owns the seam and the closed Gate_Error
// taxonomy; stage_gates is the single plug-point for the per-gate checks.
package funpack

import "core:hash"
import "core:strings"

// The structural budgets are compiler constants, not configuration: a
// gate verdict must be reproducible from the source alone, with no project
// dial to relax it.
MAX_CYCLOMATIC :: 10
MAX_NESTING_DEPTH :: 3
MAX_FN_STATEMENTS :: 40
MAX_PARAM_ARITY :: 5

// MAX_DUPLICATE_UNITS is the §01 P5 duplication threshold (§01 §4 policy
// table) as a fixed
// compiler constant: at most this many declaration units may share a
// dup_class (the §29 normalized-AST hash). Two structurally identical
// units modulo bound-name alpha-renaming is one too many, so the ceiling
// is 1 — there is no per-site waiver and no project dial to relax it.
MAX_DUPLICATE_UNITS :: 1

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
// TODO: the cyclomatic, nesting, fn-size, arity, and exhaustiveness checks
// plug in here alongside the duplication gate; until each lands its arm is
// deliberately pass-through.
stage_gates :: proc(ast: Ast) -> Gate_Error {
	if gate_duplication(ast) != .None {
		return .Duplicate_Declaration
	}
	return .None
}

// gate_duplication enforces §29's dup_class rule: each test-block body is
// the declaration unit, canonicalized to a normalized-AST string and
// hashed into a dup_class key. Two units that normalize to the same key
// are structurally identical modulo bound-name alpha-renaming, which
// overshoots MAX_DUPLICATE_UNITS and is a compile error. The whole-block
// body (not the single assert) is the §29-faithful unit: per-assert
// hashing would false-positive on legitimately similar single asserts
// (e.g. the golden file's repeated `assert a.slerp(b, …) == …` shapes).
gate_duplication :: proc(ast: Ast) -> Gate_Error {
	seen := make(map[u64]int, context.temp_allocator)
	for test in ast.tests {
		key := dup_class(test.body)
		seen[key] += 1
		if seen[key] > MAX_DUPLICATE_UNITS {
			return .Duplicate_Declaration
		}
	}
	return .None
}

// dup_class hashes a declaration unit's normalized-AST string into the
// §29 dup_class key. The fnv64a digest over the canonical bytes is the
// hash; structurally identical units (modulo alpha-renaming) canonicalize
// to the same bytes and so collide on the same key.
dup_class :: proc(body: []Statement) -> u64 {
	b := strings.builder_make(context.temp_allocator)
	// alpha holds the in-order bound-name frame: let bindings and lambda
	// params push their names here, so a Name_Expr referencing a bound
	// name canonicalizes to its binding slot index, not its spelling — a
	// rename-only variant produces identical bytes and so cannot dodge
	// the gate.
	alpha := make([dynamic]string, 0, 8, context.temp_allocator)
	canon_body(&b, body, &alpha)
	return hash.fnv64a(transmute([]byte)strings.to_string(b))
}

// canon_body emits the canonical form of a test-block body: each
// statement in order, against the shared alpha frame so let bindings
// stay visible to the asserts that follow them.
canon_body :: proc(b: ^strings.Builder, body: []Statement, alpha: ^[dynamic]string) {
	strings.write_string(b, "(body")
	for stmt in body {
		switch s in stmt {
		case Let_Node:
			strings.write_string(b, " (let ")
			canon_expr(b, s.value, alpha)
			strings.write_byte(b, ')')
			// The binding becomes visible only AFTER its initializer, so
			// the slot is pushed once the value is canonicalized.
			append(alpha, s.name)
		case Assert_Node:
			strings.write_string(b, " (assert ")
			canon_expr(b, s.expr, alpha)
			strings.write_byte(b, ')')
		}
	}
	strings.write_byte(b, ')')
}

// canon_expr writes the canonical, alpha-normalized form of an
// expression. Every node opens with a kind tag, so two trees of
// different shape can never collide; a bound name resolves to its
// frame slot (alpha-renamed), while a free name (an imported function,
// a type, a field) keeps its spelling — renaming a free name is a real
// structural change, renaming a binding is not.
canon_expr :: proc(b: ^strings.Builder, expr: Expr, alpha: ^[dynamic]string) {
	switch e in expr {
	case ^Int_Lit_Expr:
		strings.write_string(b, "(int ")
		strings.write_i64(b, e.value)
		strings.write_byte(b, ')')
	case ^Fixed_Lit_Expr:
		strings.write_string(b, "(fixed ")
		strings.write_i64(b, i64(e.bits))
		strings.write_byte(b, ')')
	case ^Name_Expr:
		canon_name(b, e.name, alpha)
	case ^Call_Expr:
		strings.write_string(b, "(call ")
		canon_expr(b, e.callee, alpha)
		for arg in e.args {
			strings.write_byte(b, ' ')
			canon_expr(b, arg, alpha)
		}
		strings.write_byte(b, ')')
	case ^Member_Expr:
		strings.write_string(b, "(member ")
		canon_expr(b, e.receiver, alpha)
		// A member name is a structural selector (`.slerp`, `.MAX`), not a
		// binding, so it keeps its spelling — alpha-renaming never touches it.
		strings.write_byte(b, ' ')
		strings.write_string(b, e.member)
		strings.write_byte(b, ')')
	case ^Variant_Expr:
		strings.write_string(b, "(variant ")
		strings.write_string(b, e.type_name)
		strings.write_byte(b, ' ')
		strings.write_string(b, e.variant)
		for arg in e.payload {
			strings.write_byte(b, ' ')
			canon_expr(b, arg, alpha)
		}
		strings.write_byte(b, ')')
	case ^Record_Expr:
		strings.write_string(b, "(record ")
		strings.write_string(b, e.type_name)
		for field in e.fields {
			strings.write_string(b, " (")
			strings.write_string(b, field.name)
			strings.write_byte(b, ' ')
			canon_expr(b, field.value, alpha)
			strings.write_byte(b, ')')
		}
		strings.write_byte(b, ')')
	case ^List_Expr:
		strings.write_string(b, "(list")
		for el in e.elements {
			strings.write_byte(b, ' ')
			canon_expr(b, el, alpha)
		}
		strings.write_byte(b, ')')
	case ^Lambda_Expr:
		strings.write_string(b, "(lambda")
		// Params bind only inside the body. They push positional slots
		// onto the shared frame for the body walk, then pop — so the
		// lambda's bindings never leak to following statements and a
		// param rename canonicalizes away.
		base := len(alpha)
		for p in e.params {
			append(alpha, p)
		}
		strings.write_string(b, " (body ")
		canon_expr(b, e.body, alpha)
		strings.write_byte(b, ')')
		resize(alpha, base)
		strings.write_byte(b, ')')
	case ^Unary_Expr:
		strings.write_string(b, "(unary ")
		strings.write_string(b, op_tag(e.op))
		strings.write_byte(b, ' ')
		canon_expr(b, e.operand, alpha)
		strings.write_byte(b, ')')
	case ^Binary_Expr:
		strings.write_string(b, "(binary ")
		strings.write_string(b, op_tag(e.op))
		strings.write_byte(b, ' ')
		canon_expr(b, e.lhs, alpha)
		strings.write_byte(b, ' ')
		canon_expr(b, e.rhs, alpha)
		strings.write_byte(b, ')')
	case ^Match_Expr:
		strings.write_string(b, "(match ")
		canon_expr(b, e.scrutinee, alpha)
		for arm in e.arms {
			canon_arm(b, arm, alpha)
		}
		strings.write_byte(b, ')')
	case nil:
		strings.write_string(b, "(nil)")
	}
}

// canon_name resolves a name to its alpha-renamed form: a bound name
// (let binding or lambda param) emits its innermost frame slot, so any
// rename of that binding is invisible; a free name keeps its spelling.
// The slot is the latest binding of the name (shadowing-correct), found
// by scanning the frame from the top.
canon_name :: proc(b: ^strings.Builder, name: string, alpha: ^[dynamic]string) {
	for i := len(alpha) - 1; i >= 0; i -= 1 {
		if alpha[i] == name {
			strings.write_string(b, "(bound ")
			strings.write_int(b, i)
			strings.write_byte(b, ')')
			return
		}
	}
	strings.write_string(b, "(free ")
	strings.write_string(b, name)
	strings.write_byte(b, ')')
}

// canon_arm canonicalizes one match arm: the pattern shape, then the
// body against a frame extended with the arm's payload binders (which
// scope only to that arm's body).
canon_arm :: proc(b: ^strings.Builder, arm: Match_Arm, alpha: ^[dynamic]string) {
	strings.write_string(b, " (arm ")
	switch arm.pattern.kind {
	case .Wildcard:
		strings.write_string(b, "wild")
	case .Bare_Variant:
		strings.write_string(b, "bare ")
		strings.write_string(b, arm.pattern.type_name)
		strings.write_byte(b, ' ')
		strings.write_string(b, arm.pattern.variant)
	case .Variant_Binds:
		strings.write_string(b, "binds ")
		strings.write_string(b, arm.pattern.type_name)
		strings.write_byte(b, ' ')
		strings.write_string(b, arm.pattern.variant)
	}
	base := len(alpha)
	for binder in arm.pattern.binders {
		append(alpha, binder)
	}
	strings.write_byte(b, ' ')
	canon_expr(b, arm.body, alpha)
	resize(alpha, base)
	strings.write_byte(b, ')')
}

// op_tag maps an operator token to its canonical glyph tag. Glyph
// operators key by kind; the word operators `and`/`or`/`not` arrive as
// Ident tokens and key by text.
op_tag :: proc(tok: Token) -> string {
	#partial switch tok.kind {
	case .Eq_Eq:
		return "=="
	case .Not_Eq:
		return "!="
	case .Lt:
		return "<"
	case .Lt_Eq:
		return "<="
	case .Gt:
		return ">"
	case .Gt_Eq:
		return ">="
	case .Plus:
		return "+"
	case .Minus:
		return "-"
	case .Star:
		return "*"
	case .Slash:
		return "/"
	case .Percent:
		return "%"
	case .Ident:
		return tok.text
	}
	return "?"
}
