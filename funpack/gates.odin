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
	Query_Missing_Index,    // a query whose body runs a spatial combinator over all[T] without declaring @spatial(T.*) on that query (spec §08 §3: a query needing an index must declare it)
	Query_Unused_Index,     // a declared @index/@spatial no read in the query's body uses — dead code (spec §08 §3 / §01 P5)
	Probe_Wrong_Placement,  // a §05 §5 debug probe on a declaration the §28 §4 On-table does not admit — a declaration-prefix @break/@log/@watch/@trace sits only on a behavior (the field/stage positions @watch/@trace also admit are sub-declaration sites the parser already gates); a decl-prefix probe on a data/enum/thing/signal/fn/query/pipeline/let/extern_type/test declaration is this verdict (probe_placement_gate.odin)
}

// Gate_Unit is one declaration body the structural gates score: a test
// block, a top-level fn, or a behavior's reserved `step`. Each carries its
// declaration name (the diagnostic anchor — a gate verdict names the
// declaration, never a test-block index), the declaration's 1-based source
// line (the §15 span the fix-criteria diagnostic anchors the offending
// declaration at — gate offenders are declaration-anchored, so this line, not
// an expression column, locates the budget overshoot), and its statement
// sequence. Every gate folds over the same unit set with the same fixed
// budgets, so a fn body and a test block are held to one ceiling (spec §01 P5:
// no per-site waiver).
Gate_Unit :: struct {
	name: string,
	line: int,
	body: []Statement,
}

// gate_units collects every declaration body the gates score, in the Ast's
// source-ordered declaration sequence — the same order the index derivation
// and the release walkers read — so a multi-violation source always reports
// the same first offender, and that offender matches index order. Only the
// body-bearing kinds contribute units (test, fn, query, behavior step); the
// body-less kinds are skipped. A behavior step's unit name is the behavior's
// own name, not the reserved `step`, so the diagnostic anchors on the
// behavior the author wrote. An `extern fn` (§26) has NO body — its
// implementation is the engine's, not the source's — so it is not a code unit
// the structural gates score: skipping it keeps the §17 seam's two body-less
// accessors (`extern fn arena_spawns`, `extern fn arena`) from colliding on
// the duplication gate (two empty bodies hash identically), which would be a
// false positive since neither carries code. A HOLED fn or behavior step
// (§05 §2: `@stub(…)` stands in body position) is body-less for the same
// reason — the hole replaces the statement sequence — so it is skipped on the
// same grounds: two holes in one module must not collide on the duplication
// gate (dev mode compiles holes; only release bans them).
gate_units :: proc(ast: Ast) -> []Gate_Unit {
	units := make([dynamic]Gate_Unit, 0, len(ast.decls), context.temp_allocator)
	for ref in ast.decls {
		#partial switch ref.kind {
		case .Test:
			test := ast.tests[ref.index]
			append(&units, Gate_Unit{name = test.name, line = test.line, body = test.body})
		case .Fn:
			fn := ast.fns[ref.index]
			if fn.is_extern || fn.holed {
				continue
			}
			append(&units, Gate_Unit{name = fn.name, line = fn.line, body = fn.body})
		case .Query:
			// A query body is a code unit like a fn body — the §01 P5 no-per-site-
			// waiver rule holds it to the same fixed budgets. The grammar admits no
			// body-position hole on a query (fun.ebnf §7: QueryDecl takes a Block,
			// never a StubExpr), so there is no holed-skip arm here.
			query := ast.queries[ref.index]
			append(&units, Gate_Unit{name = query.name, line = query.line, body = query.body})
		case .Behavior:
			behavior := ast.behaviors[ref.index]
			if behavior.step.holed {
				continue
			}
			// The behavior's OWN line anchors the diagnostic (its declaration line,
			// not the reserved `step`'s), matching the behavior-named offender.
			append(&units, Gate_Unit{name = behavior.name, line = behavior.line, body = behavior.step.body})
		}
	}
	return units[:]
}

// release_holed_decl returns the first §05 typed-hole declaration in one AST —
// a holed fn or behavior step (the body-position FnBody hole) OR any
// declaration whose expression trees carry a §15 StubExpr expression-position
// hole (a field default, a fn/step body, a `let` initializer, a test body).
// Declarations walk in the Ast's source-ordered declaration sequence — the
// same order derive_decl_records emits and release_debug_decl walks — so a
// multi-hole source always names the same first offender deterministically,
// and that offender is the first holed declaration in INDEX order. It is the
// pure-AST half of the §29 §4 release hole-ban ("you cannot ship a hole"):
// the verdict is a function of the AST alone, and the CALLER (stage_build)
// supplies the mode — in dev the finder is never consulted, under --release
// any hit is a compile error. The returned declaration name is the behavior's
// own name for a holed step (the diagnostic anchor, never the reserved
// `step`). The switch is total over Ast_Decl_Kind, so a new declaration kind is a
// visible compile gap here, never a silently-unwalked hole position.
release_holed_decl :: proc(ast: Ast) -> (declaration: string, holed: bool) {
	for ref in ast.decls {
		switch ref.kind {
		case .Data:
			decl := ast.datas[ref.index]
			if fields_hold_stub(decl.fields) {
				return decl.name, true
			}
		case .Enum:
			decl := ast.enums[ref.index]
			if variants_hold_stub(decl.variants) {
				return decl.name, true
			}
		case .Thing:
			decl := ast.things[ref.index]
			if fields_hold_stub(decl.fields) {
				return decl.name, true
			}
		case .Signal:
			decl := ast.signals[ref.index]
			if fields_hold_stub(decl.fields) {
				return decl.name, true
			}
		case .Fn:
			fn := ast.fns[ref.index]
			if fn_holds_stub(fn) {
				return fn.name, true
			}
		case .Query:
			// A query admits no body-position hole (fun.ebnf §7), but a §15
			// StubExpr expression-position hole may stand in any body expression —
			// the same release ban applies, so the body walk runs here too.
			query := ast.queries[ref.index]
			if body_holds_stub(query.body) {
				return query.name, true
			}
		case .Behavior:
			behavior := ast.behaviors[ref.index]
			if fn_holds_stub(behavior.step) {
				return behavior.name, true
			}
		case .Pipeline:
			// A pipeline declares stage names only — no expression position, so
			// it can never hole.
		case .Let:
			decl := ast.lets[ref.index]
			if expr_holds_stub(decl.value) {
				return decl.name, true
			}
		case .Test:
			decl := ast.tests[ref.index]
			if body_holds_stub(decl.body) {
				return decl.name, true
			}
		case .Extern_Type:
			// An opaque type carries no fields and no body (§26 §2) — no
			// expression position, so it can never hole.
		}
	}
	return "", false
}

// fn_holds_stub reports whether a fn / behavior-step declaration carries a §05
// typed hole in EITHER position: the body-position FnBody hole the parser
// records (Fn_Node.holed — its fallback is part of the hole, never a separate
// verdict) or a §15 StubExpr expression-position hole anywhere in its intact
// statement body. This is the per-decl verdict the release hole-ban and the
// §29 §2 `stub` index field both derive from, so the two surfaces can never
// disagree on what counts as a hole.
fn_holds_stub :: proc(fn: Fn_Node) -> bool {
	if fn.holed {
		return true
	}
	return body_holds_stub(fn.body)
}

// body_holds_stub folds the expression-hole scan over a statement body,
// descending an `if` guard's condition and its nested block so a hole under
// an early-return guard (or inside a test's assert) is still found.
body_holds_stub :: proc(body: []Statement) -> bool {
	for stmt in body {
		switch s in stmt {
		case Let_Node:
			if expr_holds_stub(s.value) {
				return true
			}
		case Assert_Node:
			if expr_holds_stub(s.expr) {
				return true
			}
		case Return_Node:
			if expr_holds_stub(s.value) {
				return true
			}
		case If_Node:
			if expr_holds_stub(s.cond) || body_holds_stub(s.body) {
				return true
			}
		}
	}
	return false
}

// fields_hold_stub reports whether any field default of a data/thing/signal
// declaration carries an expression-position hole. A defaulted field is the
// only expression position those declarations own; default is meaningless
// when has_default is false (Field_Decl), so only set defaults are scanned.
fields_hold_stub :: proc(fields: []Field_Decl) -> bool {
	for field in fields {
		if field.has_default && expr_holds_stub(field.default) {
			return true
		}
	}
	return false
}

// variants_hold_stub reports whether any struct-payload variant field default
// of an enum declaration carries an expression-position hole — the one
// expression position an enum declaration owns (a plain or tuple-payload
// variant carries types only).
variants_hold_stub :: proc(variants: []Variant_Decl) -> bool {
	for variant in variants {
		if fields_hold_stub(variant.fields) {
			return true
		}
	}
	return false
}

// expr_holds_stub reports whether an expression tree contains a §05 §2
// expression-position typed hole (grammar/fun.ebnf §15: StubExpr is an Atom).
// It mirrors the Expr union arm-for-arm so a new expression form is a visible
// compile gap here, not a silently-unwalked branch — the same totality the
// gate walks keep. A Stub_Expr node is itself the verdict (its fallback is
// part of the hole, never a separate finding).
expr_holds_stub :: proc(expr: Expr) -> bool {
	switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr, ^All_Expr:
		return false
	case ^Stub_Expr:
		return true
	case ^Call_Expr:
		if expr_holds_stub(e.callee) {
			return true
		}
		for arg in e.args {
			if expr_holds_stub(arg) {
				return true
			}
		}
	case ^Member_Expr:
		return expr_holds_stub(e.receiver)
	case ^Variant_Expr:
		for arg in e.payload {
			if expr_holds_stub(arg) {
				return true
			}
		}
		for field in e.fields {
			if expr_holds_stub(field.value) {
				return true
			}
		}
	case ^Record_Expr:
		for field in e.fields {
			if expr_holds_stub(field.value) {
				return true
			}
		}
	case ^List_Expr:
		for element in e.elements {
			if expr_holds_stub(element) {
				return true
			}
		}
	case ^Lambda_Expr:
		return expr_holds_stub(e.body)
	case ^Unary_Expr:
		return expr_holds_stub(e.operand)
	case ^Binary_Expr:
		return expr_holds_stub(e.lhs) || expr_holds_stub(e.rhs)
	case ^With_Expr:
		if expr_holds_stub(e.base) {
			return true
		}
		for field in e.fields {
			if expr_holds_stub(field.value) {
				return true
			}
		}
	case ^Match_Expr:
		if expr_holds_stub(e.scrutinee) {
			return true
		}
		for arm in e.arms {
			if expr_holds_stub(arm.body) {
				return true
			}
		}
	case ^Tuple_Expr:
		for element in e.elements {
			if expr_holds_stub(element) {
				return true
			}
		}
	case ^If_Expr:
		return expr_holds_stub(e.cond) || expr_holds_stub(e.then_branch) || expr_holds_stub(e.else_branch)
	}
	return false
}

// release_debug_decl returns the first declaration carrying a §05 §5 debug
// probe (@break/@log/@watch/@trace) in one AST — the pure-AST half of the §29
// §3 release debug-directive ban ("debug residue can neither ship nor rot",
// §28 §4), the exact sibling of release_holed_decl: the verdict is a function
// of the AST alone, and the CALLER (stage_build) supplies the mode — in dev
// the finder is never consulted, under --release any hit is a compile error.
// Declarations walk in the Ast's source-ordered declaration sequence — the
// same order derive_decl_records emits and release_holed_decl walks — so a
// multi-probe source always names the same first offender deterministically,
// and that offender is the first probed declaration in INDEX order.
//
// A probe rides one of THREE AST positions and the ban is placement-BLIND
// across all of them (residue cannot ship even when mis-placed — the §28 §4
// placement gate refuses a mis-placed probe separately, but a release build
// must never carry a probe at any position): a declaration prefix
// (decl.probes), a `data`-field prefix (Field_Decl.probes — the §28 §4 On-table
// admits @watch there), or a pipeline-stage prefix (Pipeline_Stage.probes — the
// On-table admits @trace there). A declaration whose own prefix is probe-free
// but which carries a field or stage probe is still the offender, named by the
// declaration the probe rides, so a field @watch or a stage @trace can no more
// slip through a --release build than a declaration-prefix probe. A test block
// carries a probe only when one is mis-placed before it (the parser carries it
// so the placement gate names the test); the ban catches it too, since debug
// residue cannot ship even on a test.
release_debug_decl :: proc(ast: Ast) -> (declaration: string, probed: bool) {
	for ref in ast.decls {
		switch ref.kind {
		case .Data:
			decl := ast.datas[ref.index]
			if len(decl.probes) > 0 || fields_hold_probe(decl.fields) {
				return decl.name, true
			}
		case .Enum:
			decl := ast.enums[ref.index]
			if len(decl.probes) > 0 || variants_hold_probe(decl.variants) {
				return decl.name, true
			}
		case .Thing:
			decl := ast.things[ref.index]
			if len(decl.probes) > 0 || fields_hold_probe(decl.fields) {
				return decl.name, true
			}
		case .Signal:
			decl := ast.signals[ref.index]
			if len(decl.probes) > 0 || fields_hold_probe(decl.fields) {
				return decl.name, true
			}
		case .Fn:
			decl := ast.fns[ref.index]
			if len(decl.probes) > 0 {
				return decl.name, true
			}
		case .Query:
			decl := ast.queries[ref.index]
			if len(decl.probes) > 0 {
				return decl.name, true
			}
		case .Behavior:
			decl := ast.behaviors[ref.index]
			if len(decl.probes) > 0 {
				return decl.name, true
			}
		case .Pipeline:
			decl := ast.pipelines[ref.index]
			if len(decl.probes) > 0 || stages_hold_probe(decl.stages) {
				return decl.name, true
			}
		case .Let:
			decl := ast.lets[ref.index]
			if len(decl.probes) > 0 {
				return decl.name, true
			}
		case .Test:
			decl := ast.tests[ref.index]
			if len(decl.probes) > 0 {
				return decl.name, true
			}
		case .Extern_Type:
			decl := ast.extern_types[ref.index]
			if len(decl.probes) > 0 {
				return decl.name, true
			}
		}
	}
	return "", false
}

// fields_hold_probe reports whether any field of a data/thing/signal
// declaration carries a §05 §5 debug probe — the §28 §4 On-table admits a
// @watch on a `data` field, and the release ban must catch it too (a field
// @watch cannot ship). A `thing`/`signal` field never carries a probe in a
// parseable tree (parse_field_list admits a field @watch only in a `data`
// body), so the walk reports false for them; it stays total so a future
// admitted field probe is caught without re-editing the ban.
fields_hold_probe :: proc(fields: []Field_Decl) -> bool {
	for field in fields {
		if len(field.probes) > 0 {
			return true
		}
	}
	return false
}

// variants_hold_probe reports whether any struct-payload variant field of an
// enum declaration carries a debug probe — the one field position an enum
// declaration owns. A variant field never carries a probe in a parseable tree
// (parse_field_list for a variant body is not a `data` body), so this reports
// false; it stays total for the same reason fields_hold_probe is.
variants_hold_probe :: proc(variants: []Variant_Decl) -> bool {
	for variant in variants {
		if fields_hold_probe(variant.fields) {
			return true
		}
	}
	return false
}

// stages_hold_probe reports whether any stage of a pipeline declaration carries
// a §05 §5 debug probe — the §28 §4 On-table admits a @trace on a stage, and
// the release ban must catch it too (a stage @trace cannot ship).
stages_hold_probe :: proc(stages: []Pipeline_Stage) -> bool {
	for stage in stages {
		if len(stage.probes) > 0 {
			return true
		}
	}
	return false
}

// Gate_Verdict pairs a gate failure with the declaration body it indicts, so
// the diagnostic names the declaration (a fn, a behavior, or a test block) —
// never a positional test-block index (spec §01 P5: the budget is a
// per-declaration compiler constant). declaration is "" only when err is None,
// or for the duplication gate, whose violation is a colliding PAIR of units,
// not a single overshooting one. line is the offending declaration's 1-based
// source line (unit.line — the §15 span the fix-criteria diagnostic anchors at),
// 0 when no single declaration is named (None, or the duplication gate's pair).
Gate_Verdict :: struct {
	err:         Gate_Error,
	declaration: string,
	line:        int,
}

// stage_gates is the pipeline seam: it returns just the first gate error a
// source overshoots (the form the pipeline driver and the gate-error fixtures
// consume). The named-declaration diagnostic rides gate_verdict.
stage_gates :: proc(ast: Ast) -> Gate_Error {
	return gate_verdict(ast).err
}

// gate_verdict walks every declaration body and returns the first budget it
// overshoots, naming the offending declaration. The gate unit is the
// declaration body — a test block, a top-level fn, or a behavior step
// (gate_units) — so the fixed budgets (cyclomatic, nesting, fn size, arity,
// match exhaustiveness, duplication) hold uniformly over all code, not just
// test blocks. It returns the first violation found, in the per-gate, then
// per-unit, order below.
gate_verdict :: proc(ast: Ast) -> Gate_Verdict {
	units := gate_units(ast)
	sets := closed_variant_sets(ast)
	for unit in units {
		if len(statements_count(unit.body)) > MAX_FN_STATEMENTS {
			return Gate_Verdict{err = .Fn_Size_Exceeded, declaration = unit.name, line = unit.line}
		}
	}
	for unit in units {
		if err := gate_arity_unit(unit); err != .None {
			return Gate_Verdict{err = err, declaration = unit.name, line = unit.line}
		}
	}
	for unit in units {
		if err := check_cyclomatic(unit); err != .None {
			return Gate_Verdict{err = err, declaration = unit.name, line = unit.line}
		}
		if err := check_nesting(unit); err != .None {
			return Gate_Verdict{err = err, declaration = unit.name, line = unit.line}
		}
	}
	for unit in units {
		if err := check_match_exhaustiveness_unit(unit, sets); err != .None {
			return Gate_Verdict{err = err, declaration = unit.name, line = unit.line}
		}
	}
	// The §08 §3 index-requirement gate pairs each query's declared
	// @index/@spatial set with its body's derived access pattern
	// (query_index_gate.odin) — per-query, so it rides the same
	// first-offender discipline as the per-unit budgets above.
	if verdict := check_query_index_gate(ast); verdict.err != .None {
		return verdict
	}
	// The §28 §4 probe-placement gate validates every declaration's §05 §5
	// debug probes against the On-table (probe_placement_gate.odin) — a
	// declaration-prefix probe is admitted only on a behavior; the field/stage
	// positions @watch/@trace also admit are sub-declaration sites the parser
	// already gates. It walks the Ast's source-ordered declaration sequence, so
	// it names the first mis-placed probe's declaration the same way the
	// release debug-ban does.
	if verdict := check_probe_placement_gate(ast); verdict.err != .None {
		return verdict
	}
	if err, name, line := gate_duplication(units); err != .None {
		// The duplicate unit (the SECOND-in-source occurrence that tripped the dup
		// ceiling) is the named offender, so the diagnostic anchors on its
		// declaration line (col 0, the decl-level gate shape) rather than rendering
		// header-only at line 0.
		return Gate_Verdict{err = err, declaration = name, line = line}
	}
	return Gate_Verdict{err = .None}
}

// statements_count flattens a body into the statement sequence the fn-size
// budget counts (spec §29 §4 / §01 P5). An `if cond { … }` early-return guard
// contributes the guard statement itself plus its guarded block's statements,
// so a long guarded sequence cannot dodge the size ceiling by nesting under an
// `if`. A test body holds no `if`, so it flattens to itself.
statements_count :: proc(body: []Statement) -> []Statement {
	flat := make([dynamic]Statement, 0, len(body), context.temp_allocator)
	for stmt in body {
		append(&flat, stmt)
		if guard, is_if := stmt.(If_Node); is_if {
			inner := statements_count(guard.body)
			for s in inner {
				append(&flat, s)
			}
		}
	}
	return flat[:]
}

// gate_arity_unit rejects a Lambda_Expr whose parameter list exceeds
// MAX_PARAM_ARITY anywhere in one declaration body. It walks every statement's
// expressions — a let's value, an assert's/return's expression, an `if`
// guard's condition and its nested body — and descends every sub-expression,
// so a lambda buried in a call argument, another lambda's body, or under an
// early-return guard is still checked. Running here — before stage_typecheck —
// means an over-arity lambda is a structural Gate_Error, not a downstream type
// mismatch.
gate_arity_unit :: proc(unit: Gate_Unit) -> Gate_Error {
	return arity_walk_body(unit.body)
}

// arity_walk_body folds the arity walk over a statement body, recursing into
// an `if` guard's condition and its nested block so an over-arity lambda
// cannot hide under an early-return guard.
arity_walk_body :: proc(body: []Statement) -> Gate_Error {
	for stmt in body {
		switch s in stmt {
		case Assert_Node:
			if err := arity_walk_expr(s.expr); err != .None {
				return err
			}
		case Let_Node:
			if err := arity_walk_expr(s.value); err != .None {
				return err
			}
		case Return_Node:
			if err := arity_walk_expr(s.value); err != .None {
				return err
			}
		case If_Node:
			if err := arity_walk_expr(s.cond); err != .None {
				return err
			}
			if err := arity_walk_body(s.body); err != .None {
				return err
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
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr, ^All_Expr:
		// Leaf atoms host no sub-expressions (`all[T]` carries only its type name).
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
	case ^Tuple_Expr:
		// A tuple hosts its element expressions, any of which can nest a lambda.
		for element in e.elements {
			if err := arity_walk_expr(element); err != .None {
				return err
			}
		}
	case ^If_Expr:
		// An if-expression hosts its condition and both arm expressions, any of
		// which can nest a lambda.
		if err := arity_walk_expr(e.cond); err != .None {
			return err
		}
		if err := arity_walk_expr(e.then_branch); err != .None {
			return err
		}
		if err := arity_walk_expr(e.else_branch); err != .None {
			return err
		}
	case ^Stub_Expr:
		// A §05 §2 expression-position hole hosts a nested lambda only through
		// its fallback approximation; a bare hole hosts nothing.
		if e.has_fallback {
			return arity_walk_expr(e.fallback)
		}
	}
	return .None
}

// check_cyclomatic enforces the branch-count budget over one declaration
// body. Cyclomatic complexity is 1 + the number of decision points; the
// branching constructs are the boolean short-circuit `and`/`or` and the `if`
// early-return guard, each one decision point. The `and`/`or` operators are
// word operators carried as Ident tokens keyed by text (see infix_power in
// expr.odin), so the count keys off op text the same way — no glyph operator
// (`+`, `==`, …) is a branch. An `if` guard adds one for the branch plus the
// decisions inside its condition and nested body, so a deeply guarded body is
// scored fully.
check_cyclomatic :: proc(unit: Gate_Unit) -> Gate_Error {
	if 1 + body_decisions(unit.body) > MAX_CYCLOMATIC {
		return .Cyclomatic_Exceeded
	}
	return .None
}

// body_decisions folds the decision-point count over a statement body: each
// statement's expression short-circuits, plus one per `if` guard and the
// decisions in its condition and nested block.
body_decisions :: proc(body: []Statement) -> int {
	decisions := 0
	for stmt in body {
		switch s in stmt {
		case Let_Node:
			decisions += count_short_circuit(s.value)
		case Assert_Node:
			decisions += count_short_circuit(s.expr)
		case Return_Node:
			decisions += count_short_circuit(s.value)
		case If_Node:
			decisions += 1
			decisions += count_short_circuit(s.cond)
			decisions += body_decisions(s.body)
		}
	}
	return decisions
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
	case ^Tuple_Expr:
		// A short-circuit buried in any tuple element still counts.
		for element in e.elements {
			count += count_short_circuit(element)
		}
	case ^If_Expr:
		// An if-EXPRESSION is itself a decision point (one branch), counted the
		// same one the early-return `if` statement is in body_decisions, plus any
		// short-circuits in its condition and the two arm expressions.
		count += 1
		count += count_short_circuit(e.cond)
		count += count_short_circuit(e.then_branch)
		count += count_short_circuit(e.else_branch)
	case ^Stub_Expr:
		// A §05 §2 expression hole's fallback approximation is real dev code,
		// so a short-circuit buried in it still counts; a bare hole decides
		// nothing.
		if e.has_fallback {
			count += count_short_circuit(e.fallback)
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

// check_nesting enforces the Expr-tree nesting budget over one declaration
// body (spec §01 P5: nesting ≤ MAX_NESTING_DEPTH, a fixed compiler constant).
//
// The metric counts *computational composition* — the constructs that fold a
// sub-computation one level deeper: a call's arguments, a lambda body, a
// payload-variant constructor, a `with`-update, and a match's arm bodies.
// Each opens one nesting level. What it deliberately does NOT count is the
// flat structure the spec frames as "plainly flat", not scope-creep:
//   - operator spines (`a == b`, `-x`) and member-access receivers
//     (`Quat.identity.rotate`) pass their child's depth through unchanged;
//   - a method-call chain (`Bindings.empty().axis(…).axis(…)`) is a postfix
//     spine — the receiver passes through and only each call's arguments
//     deepen, so chaining builder calls is flat, not one level per link;
//   - a record literal (`Vec2{…}`, `Ball{…}`) and a list literal are
//     transparent aggregates — pure value construction, not control nesting —
//     so they contribute their deepest field/element value without adding a
//     level (a `[Spawn(Ball{pos: Vec2{…}})]` startup program is flat
//     construction, not depth-4 scope-creep);
//   - a match scrutinee sits at the match's own level (like an `if` guard's
//     condition), since the discriminant is computed before the branch opens;
//     only the arm bodies deepen.
// This matches spec §29 §4 / §01 P5, which frame the nesting budget as a
// *scope-creep inside one function* control on composition depth, not a count
// of every AST edge — so the canonical gameplay surface (the pong golden)
// clears it, while genuine nested computation (four nested calls, a chain of
// payload-variant constructors) still fires.
check_nesting :: proc(unit: Gate_Unit) -> Gate_Error {
	return nesting_walk_body(unit.body, 0)
}

// nesting_walk_body scores the compositional-container nesting of every
// statement in a body, with an `if` early-return guard opening one nesting
// level for its guarded block (the block is a container of statements, like a
// call's argument list opens one for its contents). depth is the level the
// body itself sits at; a guarded block recurses at depth+1. A condition
// expression is scored at the body's own depth — the guard does not deepen its
// own condition.
nesting_walk_body :: proc(body: []Statement, depth: int) -> Gate_Error {
	for stmt in body {
		switch s in stmt {
		case Let_Node:
			if depth + nesting_depth(s.value) > MAX_NESTING_DEPTH {
				return .Nesting_Exceeded
			}
		case Assert_Node:
			if depth + nesting_depth(s.expr) > MAX_NESTING_DEPTH {
				return .Nesting_Exceeded
			}
		case Return_Node:
			if depth + nesting_depth(s.value) > MAX_NESTING_DEPTH {
				return .Nesting_Exceeded
			}
		case If_Node:
			if depth + nesting_depth(s.cond) > MAX_NESTING_DEPTH {
				return .Nesting_Exceeded
			}
			if err := nesting_walk_body(s.body, depth + 1); err != .None {
				return err
			}
		}
	}
	return .None
}

// nesting_depth returns the deepest computational-composition nesting in one
// Expr tree (the check_nesting metric). A computational construct (a call's
// arguments, a lambda body, a `with`-update, a match arm body, and a
// variant-of-variant chain link) adds one level over its contents; a transparent
// aggregate (a record or list literal, a single-wrap payload variant over a
// non-variant value), an operator spine, a member-access receiver, a
// method-call chain's receiver spine, and a match scrutinee all pass their
// child's depth through unchanged.
nesting_depth :: proc(expr: Expr) -> int {
	#partial switch e in expr {
	case ^Unary_Expr:
		return nesting_depth(e.operand)
	case ^Binary_Expr:
		return max(nesting_depth(e.lhs), nesting_depth(e.rhs))
	case ^Member_Expr:
		return nesting_depth(e.receiver)
	case ^Call_Expr:
		// A method call (callee is a member access) is a postfix spine: the
		// receiver passes through at the same depth and only the arguments
		// deepen, so a builder chain (Bindings.empty().axis(…).axis(…)) is flat,
		// not one level per chained call.
		if method, is_method := e.callee.(^Member_Expr); is_method {
			inner := nesting_depth(method.receiver)
			for arg in e.args {
				inner = max(inner, 1 + arg_nesting_depth(arg))
			}
			return inner
		}
		inner := nesting_depth(e.callee)
		for arg in e.args {
			inner = max(inner, arg_nesting_depth(arg))
		}
		return 1 + inner
	case ^Record_Expr:
		// A record literal is a transparent aggregate — pure value construction,
		// not control nesting — so it contributes its deepest field value without
		// adding a level (`cross(Vec3{…}, Vec3{…})`, `Ball{pos: Vec2{…}}` stay
		// flat).
		inner := 0
		for field in e.fields {
			inner = max(inner, nesting_depth(field.value))
		}
		return inner
	case ^List_Expr:
		// A list literal is a transparent aggregate like a record: a
		// `[Spawn(…), Spawn(…)]` startup program is flat construction.
		inner := 0
		for element in e.elements {
			inner = max(inner, nesting_depth(element))
		}
		return inner
	case ^Lambda_Expr:
		return 1 + nesting_depth(e.body)
	case ^Variant_Expr:
		// A SINGLE-WRAP payload variant is a transparent aggregate, like a record
		// or list literal: it is pure value construction (an enum value carrying a
		// payload), NOT control nesting, so it passes its deepest payload/field
		// value's depth through without adding a level. A bare variant
		// (Side::Left, Option::None) is the 0-arg leaf case; a single-wrap payload
		// variant (`Option::Some("saved")`, `Option::Some(p.pos)`, `Spawn(crate_at(…))`)
		// contributes its deepest argument's depth — so `m with { status:
		// Option::Some("saved") }` is a single `with` level over a leaf, the same
		// as `m with { status: STR }`. Spec §01 P5 frames the nesting budget as a
		// scope-creep-inside-one-function control on COMPOSITION depth, not a count
		// of constructor edges; wrapping a value in an enum case is the same flat
		// construction `Vec2{x, y}` already is (without it, the canonical yard
		// surface's `fold(_, _, fn{ match { => m with { status: Option::Some(_) }
		// } })` over-counts to depth 4 and the spec example fails its own fixed
		// budget — §24 Option::Some(...) inside with-updates inside fold lambdas).
		//
		// A VARIANT-OF-VARIANT chain still opens a level per link: when the
		// immediate payload is ITSELF a payload-bearing variant
		// (`Box::A(Box::B(Box::C(1)))`), each wrap counts, re-bounding the
		// pure-aggregate gaming vector at chain depth. The transparency is
		// strictly the single-wrap-over-a-non-variant case; the discrimination is
		// on the IMMEDIATE payload's form, not the whole subtree's.
		inner := 0
		opens_level := false
		for arg in e.payload {
			if is_payload_variant(arg) {
				opens_level = true
			}
			inner = max(inner, nesting_depth(arg))
		}
		for field in e.fields {
			if is_payload_variant(field.value) {
				opens_level = true
			}
			inner = max(inner, nesting_depth(field.value))
		}
		if opens_level {
			return 1 + inner
		}
		return inner
	case ^With_Expr:
		// A `with` update is a record-update computation: its field
		// replacements open one nesting level over the base.
		inner := nesting_depth(e.base)
		for field in e.fields {
			inner = max(inner, nesting_depth(field.value))
		}
		return 1 + inner
	case ^Match_Expr:
		// The scrutinee is the discriminant computed before the branch opens,
		// so it sits at the match's own level (like an `if` guard's condition);
		// only the arm bodies deepen.
		inner := nesting_depth(e.scrutinee)
		for arm in e.arms {
			inner = max(inner, 1 + nesting_depth(arm.body))
		}
		return inner
	case ^Tuple_Expr:
		// A tuple `(value, next_rng)` is a transparent aggregate like a record
		// or list — pure positional value construction, not control nesting —
		// so it passes its deepest element's depth through without adding a
		// level. A tuple wrapping over-nested elements still fires the gate via
		// those elements.
		inner := 0
		for element in e.elements {
			inner = max(inner, nesting_depth(element))
		}
		return inner
	case ^If_Expr:
		// An if-expression is control nesting like a match: the condition is the
		// discriminant computed before the branch opens, so it sits at the if's
		// own level (it passes through), while each arm body deepens by one.
		inner := nesting_depth(e.cond)
		inner = max(inner, 1 + nesting_depth(e.then_branch))
		inner = max(inner, 1 + nesting_depth(e.else_branch))
		return inner
	}
	// An atom (literal or bare name) is a leaf — depth zero.
	return 0
}

// is_payload_variant reports whether an expression is a payload-bearing variant
// constructor — a `Variant_Expr` carrying a tuple payload or struct fields
// (`Option::Some(v)`, `Box::A(…)`, `Draw::Rect{…}`), as opposed to a bare
// variant (`Option::None`, `Side::Left`) or any non-variant form. The nesting
// metric uses it to discriminate the single-wrap transparency from a
// variant-of-variant chain: a payload variant wrapping another payload variant
// opens a level (the chain re-bounds the gaming vector), while a payload variant
// wrapping a non-variant value is a transparent aggregate.
is_payload_variant :: proc(expr: Expr) -> bool {
	variant, is_variant := expr.(^Variant_Expr)
	if !is_variant {
		return false
	}
	return variant.has_payload || variant.has_fields
}

// arg_nesting_depth scores a call argument's nesting, collapsing an inline
// lambda argument's own closure level into the call's argument level: a
// combinator with an inline predicate (`filter(src, fn(c){ … })`,
// `first(view, fn(p){ … })`) is ONE composition level, not two. The call arm
// already adds one level for entering its argument scope, so a lambda argument
// contributes its BODY's depth, not `1 + body` — the predicate body's own
// nesting (a call inside it) still deepens, but the predicate itself is part of
// the combinator's single step. Every non-lambda argument scores normally, so a
// nested call argument (`f(g(x))`) deepens as before. Mirrors the flat builder
// chain (a method-call spine does not add a level per link).
arg_nesting_depth :: proc(arg: Expr) -> int {
	if lambda, is_lambda := arg.(^Lambda_Expr); is_lambda {
		return nesting_depth(lambda.body)
	}
	return nesting_depth(arg)
}

// gate_duplication enforces §29's dup_class rule: each declaration body — a
// test block, a fn, or a behavior step — is the declaration unit,
// canonicalized to a normalized-AST string and hashed into a dup_class key.
// Two units that normalize to the same key are structurally identical modulo
// bound-name alpha-renaming, which overshoots MAX_DUPLICATE_UNITS and is a
// compile error. The whole-body (not the single statement) is the §29-faithful
// unit: per-statement hashing would false-positive on legitimately similar
// single statements (e.g. the golden file's repeated `assert a.slerp(b, …) ==
// …` shapes, or two one-line `with`-update behaviors over different things).
// It returns the offending unit's name/line alongside the error so the
// fix-criteria diagnostic anchors on the duplicate declaration: the unit in hand
// at the reject is the SECOND-in-source occurrence (the source-order walk tripped
// the ceiling on it), the one an author removes or differentiates. name/line are
// "" / 0 on the clean (.None) verdict.
gate_duplication :: proc(units: []Gate_Unit) -> (err: Gate_Error, name: string, line: int) {
	seen := make(map[u64]int, context.temp_allocator)
	for unit in units {
		key := dup_class(unit.body)
		seen[key] += 1
		if seen[key] > MAX_DUPLICATE_UNITS {
			return .Duplicate_Declaration, unit.name, unit.line
		}
	}
	return .None, "", 0
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
		// has_payload is structural and is canonicalized: a bare variant
		// (`Foo::Bar`, has_payload=false) and an empty-payload tuple-variant
		// (`Foo::Bar()`, has_payload=true, payload=[]) are different
		// constructor forms but both have an empty payload loop below, so
		// without this marker they would emit identical bytes and collide. The
		// `(payload)` tag fires only when has_payload is set, so a non-empty
		// payload still distinguishes by its args and a bare variant stays
		// untagged.
		if e.has_payload {
			strings.write_string(b, " (payload)")
		}
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
		// The param COUNT is structural and is written into the canonical form:
		// two lambdas differing only by an unused trailing param
		// (`fn(a, x){ a }` vs `fn(a){ a }`) bind the same body slots and so
		// would otherwise canonicalize identically and collide on the
		// duplication gate. Their parameter arity differs, so they are NOT
		// alpha-equivalent — the count tag distinguishes them. Param NAMES stay
		// alpha-renamed (a rename is not a structural change); only the count is
		// emitted.
		strings.write_string(b, "(lambda ")
		strings.write_int(b, len(e.params))
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
	case ^Tuple_Expr:
		// The `tuple` kind tag keeps a tuple distinct from a list and from any
		// other aggregate, so two tuples collide on a dup_class only when their
		// element subtrees are structurally identical (modulo alpha-renaming).
		strings.write_string(b, "(tuple")
		for element in e.elements {
			strings.write_byte(b, ' ')
			canon_expr(b, element, alpha)
		}
		strings.write_byte(b, ')')
	case ^If_Expr:
		// The `if` kind tag plus its three ordered children (condition, then
		// arm, else arm) canonicalizes the conditional, so two if-expressions
		// collide on a dup_class only when condition AND both arms are
		// structurally identical (modulo alpha-renaming).
		strings.write_string(b, "(if ")
		canon_expr(b, e.cond, alpha)
		strings.write_byte(b, ' ')
		canon_expr(b, e.then_branch, alpha)
		strings.write_byte(b, ' ')
		canon_expr(b, e.else_branch, alpha)
		strings.write_byte(b, ')')
	case ^Stub_Expr:
		// A §05 §2 expression-position hole canonicalizes by its kind tag, its
		// declared T (the syntactic spelling — two holes of different type are
		// structurally different), and its fallback subtree when present, so a
		// holed expression never collides with intact code and two unlike
		// holes never collide with each other.
		strings.write_string(b, "(stub ")
		strings.write_string(b, type_ref_string(e.hole_type))
		if e.has_fallback {
			strings.write_byte(b, ' ')
			canon_expr(b, e.fallback, alpha)
		}
		strings.write_byte(b, ')')
	case ^All_Expr:
		// The §08 §3 world read canonicalizes by its kind tag and thing type
		// name — a FREE name (a type, never a binding), so it keeps its
		// spelling: two reads of different tables are structurally different.
		strings.write_string(b, "(all ")
		strings.write_string(b, e.thing)
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

// canon_arm canonicalizes one match arm: the pattern shape, the COUNT of
// binders the pattern introduces, then the body against a frame extended with
// the arm's payload binders (which scope only to that arm's body). A tuple
// pattern's binders come from its sub-patterns, collected in left-to-right
// position order so a rename canonicalizes away the same way a flat variant
// binder does.
//
// The binder count is structural and is written into the canonical form: a
// `Struct_Binds` tag (canon_pattern) carries only the (type, variant) shape and
// deliberately drops WHICH fields are punned, so without the count two
// struct-payload arms of the same variant binding different field SETS
// (`Shape2::Box{size}` vs `Shape2::Box{size, color}`) would collide on the
// duplication gate when their bodies reference the same slots. Their binder
// arities differ, so they are NOT alpha-equivalent — the count tag distinguishes
// them. Binder NAMES stay alpha-renamed (a rename is not a structural change);
// only the count is emitted.
canon_arm :: proc(b: ^strings.Builder, arm: Match_Arm, alpha: ^[dynamic]string) {
	strings.write_string(b, " (arm ")
	canon_pattern(b, arm.pattern)
	strings.write_string(b, " (binders ")
	strings.write_int(b, pattern_binder_count(arm.pattern))
	strings.write_byte(b, ')')
	base := len(alpha)
	push_pattern_binders(alpha, arm.pattern)
	strings.write_byte(b, ' ')
	canon_expr(b, arm.body, alpha)
	resize(alpha, base)
	strings.write_byte(b, ')')
}

// pattern_binder_count counts the binders a pattern introduces, mirroring
// push_pattern_binders exactly: a struct/bare binder contributes its named
// binders, and a tuple or variant-binds pattern recurses into its sub-patterns.
// It is the structural binder ARITY canon_arm encodes so two arms differing only
// by binder count cannot collide on the duplication gate.
pattern_binder_count :: proc(pattern: Pattern) -> int {
	switch pattern.kind {
	case .Wildcard, .Bare_Variant:
		return 0
	case .Struct_Binds, .Bare_Binder:
		return len(pattern.binders)
	case .Variant_Binds, .Tuple:
		count := 0
		for sub in pattern.elements {
			count += pattern_binder_count(sub)
		}
		return count
	}
	return 0
}

// canon_pattern writes a pattern's canonical shape tag — the structural form
// a dup_class keys off, with binder names omitted (a binder rename is not a
// structural change; canon_arm alpha-renames them in the body instead). A
// tuple recurses into its sub-patterns so two tuple patterns of different
// shape never collide.
canon_pattern :: proc(b: ^strings.Builder, pattern: Pattern) {
	switch pattern.kind {
	case .Wildcard:
		strings.write_string(b, "wild")
	case .Bare_Variant:
		strings.write_string(b, "bare ")
		strings.write_string(b, pattern.type_name)
		strings.write_byte(b, ' ')
		strings.write_string(b, pattern.variant)
	case .Variant_Binds:
		// The (type, variant) shape plus each payload sub-pattern's shape (grammar
		// §13: the payload is nested Patterns), so AppMsg::Hud(HudMsg::Coin) and
		// AppMsg::Hud(m) get distinct tags — a specific nested variant is a narrower
		// arm than a binding one, and the dup gate must tell them apart.
		strings.write_string(b, "binds ")
		strings.write_string(b, pattern.type_name)
		strings.write_byte(b, ' ')
		strings.write_string(b, pattern.variant)
		for sub in pattern.elements {
			strings.write_byte(b, ' ')
			canon_pattern(b, sub)
		}
	case .Struct_Binds:
		// The field-pun binder names are alpha-renamed in the body, so the
		// structural tag carries only the (type, variant) shape — two
		// struct-payload patterns of the same variant collide regardless of
		// which fields they pun.
		strings.write_string(b, "struct ")
		strings.write_string(b, pattern.type_name)
		strings.write_byte(b, ' ')
		strings.write_string(b, pattern.variant)
	case .Bare_Binder:
		// A bare binder is a structural slot; its name is alpha-renamed, so the
		// shape tag carries no name.
		strings.write_string(b, "bind")
	case .Tuple:
		strings.write_string(b, "tup")
		for sub in pattern.elements {
			strings.write_byte(b, ' ')
			canon_pattern(b, sub)
		}
	}
}

// push_pattern_binders appends a pattern's binders onto the alpha frame in
// left-to-right position order: a variant pattern's payload binders, a bare
// binder's single name, or a tuple pattern's sub-pattern binders recursively.
push_pattern_binders :: proc(alpha: ^[dynamic]string, pattern: Pattern) {
	switch pattern.kind {
	case .Wildcard, .Bare_Variant:
		// No binders.
	case .Struct_Binds, .Bare_Binder:
		for binder in pattern.binders {
			append(alpha, binder)
		}
	case .Variant_Binds:
		// The payload binders live in the nested sub-patterns now (grammar §13), so
		// recurse into each — Option::Some(v) / AppMsg::Hud(m) push their binder,
		// AppMsg::Hud(HudMsg::Coin) pushes none.
		for sub in pattern.elements {
			push_pattern_binders(alpha, sub)
		}
	case .Tuple:
		for sub in pattern.elements {
			push_pattern_binders(alpha, sub)
		}
	}
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
	// engine.prelude Result, with variants Ok and Err — the §24 outcome match
	// (Result::Ok(_)/Result::Err(_)) is forced to cover both arms, so a failed
	// save/restore can never be silently dropped (spec §24 §1, AX4).
	{type_name = "Result", variants = {"Ok", "Err"}},
	// engine.prelude Ordering, with variants Less/Equal/Greater (prelude.fun:19) —
	// the value `compare(a, b)` produces. The prelude doc "forces a match", so the
	// three-way match must cover all three arms: without this entry the gate leaves
	// an Ordering match "for a later stage" and an incomplete one would pass
	// silently (spec §02 §5: a non-total match is a compile error). The first
	// engine enum a program is expected to match exhaustively.
	{type_name = "Ordering", variants = {"Less", "Equal", "Greater"}},
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

// check_match_exhaustiveness_unit rejects any non-total match in one
// declaration body (spec §02 §5: a non-total match is a compile error). It is
// pure-AST and reads the arm patterns' own type_name/variant strings against
// the closed variant sets (the stdlib prelude plus the source's user enums),
// never a resolved scrutinee type — so a body match over a user enum (Side,
// Steer) is proven exhaustive against that enum's declared variant set
// (closed_variant_sets), just as a test-block match over Option is. It descends
// every statement's expressions, including an `if` guard's condition and its
// nested body, to find match nodes.
check_match_exhaustiveness_unit :: proc(unit: Gate_Unit, sets: []Closed_Variant_Set) -> Gate_Error {
	return match_walk_body(unit.body, sets)
}

// match_walk_body folds the match-exhaustiveness walk over a statement body,
// recursing into an `if` guard's condition and its nested block so a match
// under an early-return guard is still proven total.
match_walk_body :: proc(body: []Statement, sets: []Closed_Variant_Set) -> Gate_Error {
	for stmt in body {
		switch node in stmt {
		case Let_Node:
			if err := match_walk_expr(node.value, sets); err != .None {
				return err
			}
		case Assert_Node:
			if err := match_walk_expr(node.expr, sets); err != .None {
				return err
			}
		case Return_Node:
			if err := match_walk_expr(node.value, sets); err != .None {
				return err
			}
		case If_Node:
			if err := match_walk_expr(node.cond, sets); err != .None {
				return err
			}
			if err := match_walk_body(node.body, sets); err != .None {
				return err
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
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr, ^All_Expr:
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
	case ^Tuple_Expr:
		// A match buried in any tuple element is still checked for exhaustiveness.
		for element in e.elements {
			if err := match_walk_expr(element, sets); err != .None {
				return err
			}
		}
		return .None
	case ^If_Expr:
		// A match buried in an if-expression's condition or either arm is still
		// checked for exhaustiveness (the arena's `Option::Some(b) => if … {
		// Option::Some(p.pos) } else { Option::Some(b) }` arm body is an if-expr).
		if err := match_walk_expr(e.cond, sets); err != .None {
			return err
		}
		if err := match_walk_expr(e.then_branch, sets); err != .None {
			return err
		}
		return match_walk_expr(e.else_branch, sets)
	case ^Stub_Expr:
		// A match buried in a §05 §2 expression hole's fallback approximation
		// is still checked for exhaustiveness — the fallback runs in dev, so
		// it is never exempt from the gate. A bare hole hosts nothing.
		if e.has_fallback {
			return match_walk_expr(e.fallback, sets)
		}
		return .None
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
//
// SINGLE-TYPE ASSUMPTION (guarded below): the first-variant-arm heuristic
// fixes ONE dispatch type from the first variant arm and counts coverage
// against only that type's closed set. That is sound exactly while every
// variant arm of the match names the SAME enum type — which holds for every
// match the gate can prove today, because the resolved scrutinee has one type
// and a well-formed single-type match's arms all name it. It is NOT sound for a
// match whose arms mix variant types (arms naming both `Option::Some` and
// `Result::Ok`): counting coverage against only the first type would silently
// mis-gate (over- or under-rejecting the other type's arms). This case is
// unreachable while CLOSED_VARIANT_SETS holds only single-dispatch entries the
// scrutinee picks one of, but a future multi-type entry must not let it pass
// silently — so the guard detects a mixed-type match (more than one distinct
// closed type named across the variant arms) and SKIPS the gate, deferring to
// stage_typecheck's scrutinee-typed exhaustiveness rather than mis-counting on a
// pure-AST heuristic that cannot resolve the true dispatch type.
check_match_total :: proc(match: ^Match_Expr, sets: []Closed_Variant_Set) -> Gate_Error {
	type_name := ""
	for arm in match.arms {
		if arm.pattern.kind == .Wildcard {
			return .None
		}
		// The first variant arm fixes the type the match dispatches on;
		// every variant arm of a single-type match names that one type.
		if type_name == "" {
			type_name = arm.pattern.type_name
		}
	}
	// Guard the single-type assumption: a match mixing distinct KNOWN closed
	// types violates the first-arm heuristic, so it is left for the
	// scrutinee-typed typechecker rather than counted here. The mix only
	// matters when more than one named type is a KNOWN closed set — an arm
	// naming an unknown/empty type (a tuple arm, an unregistered enum) carries
	// no denominator and never drove the count anyway.
	if match_mixes_closed_types(match, sets) {
		return .None
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

// match_mixes_closed_types reports whether the match's variant arms name more
// than one DISTINCT known closed type — the condition that breaks the
// single-type first-arm heuristic in check_match_total. It scans every arm's
// pattern type_name (a tuple/wildcard arm names none) and counts how many
// distinct names resolve to a known closed set; two or more is a mixed-type
// match the gate cannot soundly count and must defer. Reachable only once
// CLOSED_VARIANT_SETS grows past single-dispatch entries, but the guard is
// permanent so a future multi-type entry mis-gates nothing.
match_mixes_closed_types :: proc(match: ^Match_Expr, sets: []Closed_Variant_Set) -> bool {
	first := ""
	for arm in match.arms {
		if arm.pattern.type_name == "" {
			continue
		}
		if _, known := closed_variant_set(sets, arm.pattern.type_name); !known {
			continue
		}
		if first == "" {
			first = arm.pattern.type_name
		} else if arm.pattern.type_name != first {
			return true
		}
	}
	return false
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
