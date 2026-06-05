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
	if err := check_match_exhaustiveness(ast); err != .None {
		return err
	}
	if err := gate_duplication(ast); err != .None {
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
			case Return_Node, If_Node:
				// Fn-body statements; never present in a test block, the
				// arity gate's unit.
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
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr:
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
		// A struct-payload variant (Draw::Rect{…}) hosts its field values.
		for field in e.fields {
			if err := arity_walk_expr(field.value); err != .None {
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
	case ^With_Expr:
		if err := arity_walk_expr(e.base); err != .None {
			return err
		}
		for field in e.fields {
			if err := arity_walk_expr(field.value); err != .None {
				return err
			}
		}
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
		for field in e.fields {
			count += count_short_circuit(field.value)
		}
	case ^With_Expr:
		count += count_short_circuit(e.base)
		for field in e.fields {
			count += count_short_circuit(field.value)
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
		// A bare variant (Side::Left, Option::None) carries no sub-
		// expressions — it is a 0-arg constructor, a value atom like a name
		// or constant (spec §03 §2), so it opens no nesting level. Only a
		// payload-bearing variant (Option::Some(v), Draw::Rect{…}) is a
		// compositional container that adds one level over its contents.
		if !e.has_payload && !e.has_fields {
			return 0
		}
		inner := 0
		for arg in e.payload {
			inner = max(inner, nesting_depth(arg))
		}
		for field in e.fields {
			inner = max(inner, nesting_depth(field.value))
		}
		return 1 + inner
	case ^With_Expr:
		// A `with` update is a compositional container like a record: its
		// field replacements open one nesting level over the base.
		inner := nesting_depth(e.base)
		for field in e.fields {
			inner = max(inner, nesting_depth(field.value))
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
	case Return_Node:
		// Return/If are fn-body statements, never present in a test block —
		// the gate unit. Return's value is its single contributed expr; an
		// If guard contributes no single expression here.
		return node.value
	case If_Node:
		return nil
	}
	return nil
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
		case Return_Node:
			// Return/If are fn-body statements; the dup gate's unit is the
			// test block, so these never reach canon_body. Canonicalize them
			// faithfully anyway so the function stays total over Statement.
			strings.write_string(b, " (return ")
			canon_expr(b, s.value, alpha)
			strings.write_byte(b, ')')
		case If_Node:
			strings.write_string(b, " (if ")
			canon_expr(b, s.cond, alpha)
			canon_body(b, s.body, alpha)
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
	case ^String_Lit_Expr:
		// A string literal's raw text — interpolation holes included — is
		// structural, so the canonical form keeps it verbatim.
		strings.write_string(b, "(string ")
		strings.write_string(b, e.text)
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
		// A struct-payload variant's named fields, canonicalized like a
		// record's — the field name is a structural selector, kept verbatim.
		for field in e.fields {
			strings.write_string(b, " (")
			strings.write_string(b, field.name)
			strings.write_byte(b, ' ')
			canon_expr(b, field.value, alpha)
			strings.write_byte(b, ')')
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
	case ^With_Expr:
		strings.write_string(b, "(with ")
		canon_expr(b, e.base, alpha)
		for field in e.fields {
			strings.write_string(b, " (")
			strings.write_string(b, field.name)
			strings.write_byte(b, ' ')
			canon_expr(b, field.value, alpha)
			strings.write_byte(b, ')')
		}
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

// Closed_Variant_Set names a known enum type and the full variant set the
// surface declares for it. The exhaustiveness gate computes coverage
// against this closed set — the only types it can prove total, since
// coverage means "every variant accounted for" and an open type has no
// fixed denominator.
Closed_Variant_Set :: struct {
	type_name: string,
	variants:  []string,
}

// CLOSED_VARIANT_SETS is the closed table of stdlib enum types whose
// variant set the surface fixes (spec §26 prelude). Option is the concrete
// case the golden surface and stdlib expose — engine.prelude Option, with
// variants Some and None. User enums (Side, Steer) are not listed here:
// they are derived from the source AST per file and folded in alongside
// this prelude table by closed_variant_sets, so the gate can prove
// exhaustiveness over a user enum too. Growing this static table is a
// deliberate edit, mirroring STDLIB_SURFACE.
@(rodata)
CLOSED_VARIANT_SETS := []Closed_Variant_Set{
	{type_name = "Option", variants = {"Some", "None"}},
}

// closed_variant_sets is the per-file closed table the exhaustiveness gate
// proves coverage against: the static stdlib prelude sets plus every user
// `enum` the source declares, registered with its declared variant set
// (spec §03 §2). A user enum is closed by construction — its declaration
// fixes the variant set — so a match over Side or Steer carries a known
// denominator just as a match over Option does. A `data`/`thing`/`signal`
// declares no variants, so only ast.enums contribute.
closed_variant_sets :: proc(ast: Ast) -> []Closed_Variant_Set {
	sets := make([dynamic]Closed_Variant_Set, 0, len(CLOSED_VARIANT_SETS) + len(ast.enums), context.temp_allocator)
	for set in CLOSED_VARIANT_SETS {
		append(&sets, set)
	}
	for decl in ast.enums {
		variants := make([]string, len(decl.variants), context.temp_allocator)
		for variant, i in decl.variants {
			variants[i] = variant.name
		}
		append(&sets, Closed_Variant_Set{type_name = decl.name, variants = variants})
	}
	return sets[:]
}

// closed_variant_set looks a type name up in a per-file closed table (the
// stdlib prelude plus the source's user enums). A name absent from the
// table carries no fixed denominator, so the gate leaves its match for a
// later stage.
closed_variant_set :: proc(sets: []Closed_Variant_Set, type_name: string) -> (set: Closed_Variant_Set, found: bool) {
	for candidate in sets {
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
	sets := closed_variant_sets(ast)
	for test in ast.tests {
		for stmt in test.body {
			switch node in stmt {
			case Let_Node:
				if err := match_walk_expr(node.value, sets); err != .None {
					return err
				}
			case Assert_Node:
				if err := match_walk_expr(node.expr, sets); err != .None {
					return err
				}
			case Return_Node, If_Node:
				// Fn-body statements; never present in a test block, the
				// exhaustiveness gate's unit.
			}
		}
	}
	return .None
}

// match_walk_expr descends an expression, checking every Match_Expr it
// contains (scrutinees and arm bodies nest matches). It mirrors the Expr
// union arm-for-arm so a new expression form is a visible compile gap
// here, not a silently-unwalked branch.
match_walk_expr :: proc(expr: Expr, sets: []Closed_Variant_Set) -> Gate_Error {
	switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr:
		return .None
	case ^Call_Expr:
		if err := match_walk_expr(e.callee, sets); err != .None {
			return err
		}
		for arg in e.args {
			if err := match_walk_expr(arg, sets); err != .None {
				return err
			}
		}
		return .None
	case ^Member_Expr:
		return match_walk_expr(e.receiver, sets)
	case ^Variant_Expr:
		for arg in e.payload {
			if err := match_walk_expr(arg, sets); err != .None {
				return err
			}
		}
		for field in e.fields {
			if err := match_walk_expr(field.value, sets); err != .None {
				return err
			}
		}
		return .None
	case ^Record_Expr:
		for field in e.fields {
			if err := match_walk_expr(field.value, sets); err != .None {
				return err
			}
		}
		return .None
	case ^List_Expr:
		for element in e.elements {
			if err := match_walk_expr(element, sets); err != .None {
				return err
			}
		}
		return .None
	case ^Lambda_Expr:
		return match_walk_expr(e.body, sets)
	case ^Unary_Expr:
		return match_walk_expr(e.operand, sets)
	case ^Binary_Expr:
		if err := match_walk_expr(e.lhs, sets); err != .None {
			return err
		}
		return match_walk_expr(e.rhs, sets)
	case ^With_Expr:
		if err := match_walk_expr(e.base, sets); err != .None {
			return err
		}
		for field in e.fields {
			if err := match_walk_expr(field.value, sets); err != .None {
				return err
			}
		}
		return .None
	case ^Match_Expr:
		if err := match_walk_expr(e.scrutinee, sets); err != .None {
			return err
		}
		for arm in e.arms {
			if err := match_walk_expr(arm.body, sets); err != .None {
				return err
			}
		}
		return check_match_total(e, sets)
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
check_match_total :: proc(match: ^Match_Expr, sets: []Closed_Variant_Set) -> Gate_Error {
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
	set, known := closed_variant_set(sets, type_name)
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
