// Per-declaration `decl` record DERIVATION (spec §29 §2): the source-derived
// half of the Index Contract that fills the fixed Decl_Record shape
// (index_contract.odin) from the already-compiled Typed_Ast + Flattened_Pipeline.
// It is a pure projection (spec §29 §1) — the Ast's source-ordered declaration
// sequence, no map iteration reaching output, no clock, no float — so the
// emitted NDJSON `decl` stream is byte-identical on every machine.
//
// Field-by-field, where each value comes from TODAY:
//   - qualified_name — the §15 module-qualified name; the module is "" on the
//     single-source path (lore #11), so qualified_name is the bare decl name,
//     never a host path. "<module>.<name>" only once the module is non-empty.
//   - kind           — the AST node type → Index_Decl_Kind (a bodied fn is Fn,
//     an `is_extern` fn is Extern_Fn).
//   - span           — the 1-based decl-keyword line the parser now threads onto
//     EVERY declaration node (parser.odin Token.line).
//   - doc / gtags    — captured on every node by the parser (@doc/@gtag, §05).
//   - dup_class      — gates.odin dup_class(body) for the body-bearing units
//     (fn / behavior-step / test); 0 for the body-less decls, mirroring
//     gate_units' extern-skip rationale so two empty bodies never collide.
//   - emits/consumes — the §04 signal routes (pipeline_flatten.odin
//     build_routes/Signal_Route): a behavior at a route's producer endpoint
//     emits that signal, at a consumer endpoint consumes it. Behavior-scoped —
//     a fn/data/let has empty emits/consumes.
//   - calls          — the callee identifier names of Call_Expr nodes reachable
//     in a body, deduped in first-seen order (a deterministic graph walk).
//   - mut_data       — the `data`/thing a behavior mutates: its `on Thing`
//     target when its return writes the blackboard (contracts.odin
//     writes_own_blackboard over write_of_return). [] for a fn/data or a
//     non-mutating behavior.
//   - stub           — the §05 §2 typed-hole verdict over BOTH hole positions
//     (fn_holds_stub, gates.odin — the same per-decl verdict the release
//     hole-ban reads): the body-position flag the parser records on a
//     body-bearing fn / behavior-step (Fn_Node.holed) OR a §15 StubExpr
//     expression-position hole anywhere in the declaration's expression trees
//     (a fn/step/test body, a `let` initializer, a field default). A decl
//     with no expression position (an empty data/thing/signal, an enum with
//     no struct-payload defaults, a pipeline) emits false.
//   - todo           — the §05 §2 @todo notes the parser records on every
//     directive-carrying declaration node (node.todos): true exactly when at
//     least one `@todo("msg", window)` is attached (todo_flag). The record
//     carries the FLAG only — the parsed message/window stay AST-side, since
//     §29 §2 names `todo` without content (a richer projection is a contract
//     reshape, not this derivation).
//   - debug          — the §05 §5 debug-probe directive names the declaration
//     carries across ALL THREE §28 §4 probe positions: its declaration-prefix
//     probes (node.probes) plus, for a data/thing/signal, every field's @watch
//     (Field_Decl.probes — decl_probes_with_fields) and, for a pipeline, every
//     stage's @trace (Pipeline_Stage.probes — decl_probes_with_stages). One
//     lowercase directive name per probe ("break"/"log"/"watch"/"trace") in
//     source order (declaration-prefix first, then fields/stages), never
//     deduped — the §28 §4 task-registration surface reports EVERY outstanding
//     probe, so a field @watch or a stage @trace surfaces on its carrying
//     declaration's record, never unindexed. [] on a probe-free decl. A test
//     block carries a probe only when one is mis-placed before it (the §28 §4
//     placement gate then refuses the build, so a valid tree's test is []).
//   - exposed        — the §05 §4 @expose flag the parser records on every
//     directive-carrying declaration node (node.exposed, v5): true exactly
//     when the declaration is published into the package/mod external
//     contract (§30 §6, §27 §2). false on a test block (the parser attaches
//     no @expose to a test).
//
// Declaration ORDER is the Ast's source-ordered declaration sequence (the
// parser appends one Decl_Ref per declaration in parse order, ADR
// 2026-06-10-formatter-canon-source-ordered-declarations), so the vector —
// and the emitted NDJSON — mirrors the authored source and is stable across
// runs and machines. The release hole/debug walkers (gates.odin) read the
// same sequence, so a refusal's first offender always matches index order.
//
// A `query` declaration (§08 §3) projects exactly as far as §29 §2's field
// enumeration admits — qualified_name/kind/span/doc/gtags/stub/todo/debug plus
// the body-derived calls/dup_class; a query takes no resources and emits
// nothing, so emits/consumes/mut_data are constant-empty. Its §05 §3
// @index/@spatial requirements are NOT projected: the enumeration names no
// index/spatial fields, so they stay AST-side (a richer projection is a
// contract reshape, not this derivation).
package funpack

import "core:slice"
import "core:strings"

// derive_decl_records projects every source declaration of a compiled program
// onto the §29 §2 Decl_Record shape, in the Ast's source-ordered declaration
// sequence (one Decl_Ref per declaration in parse order), so the derived
// []Decl_Record is byte-deterministic and mirrors the authored source. The
// signal routes (flat.routes) supply the per-behavior emits/consumes; the typed
// env supplies the behavior signatures mut_data reads; the parser nodes supply
// the rest. The module is the §15 path-derived module name — "" on the
// single-source path (lore #11), so qualified_name is the bare decl name there.
// Every field is temp-allocated like build_project_record's derived fields, so
// the records are pure projections the emitter marshals straight onto NDJSON.
derive_decl_records :: proc(module: string, typed: Typed_Ast, flat: Flattened_Pipeline) -> []Decl_Record {
	ast := typed.ast
	records := make([dynamic]Decl_Record, 0, len(ast.decls), context.temp_allocator)

	// The switch is total over Ast_Decl_Kind, so a new declaration kind is a
	// visible compile gap here, never a silently-unindexed branch.
	for ref in ast.decls {
		switch ref.kind {
		case .Data:
			decl := ast.datas[ref.index]
			append(&records, body_less_decl(module, decl.name, .Data, decl.line, decl.doc, decl.gtags, decl.todos, decl_probes_with_fields(decl.probes, decl.fields), fields_hold_stub(decl.fields), decl.exposed))
		case .Enum:
			decl := ast.enums[ref.index]
			append(&records, body_less_decl(module, decl.name, .Enum, decl.line, decl.doc, decl.gtags, decl.todos, decl_probes_with_variant_fields(decl.probes, decl.variants), variants_hold_stub(decl.variants), decl.exposed))
		case .Thing:
			decl := ast.things[ref.index]
			append(&records, body_less_decl(module, decl.name, .Thing, decl.line, decl.doc, decl.gtags, decl.todos, decl_probes_with_fields(decl.probes, decl.fields), fields_hold_stub(decl.fields), decl.exposed))
		case .Signal:
			decl := ast.signals[ref.index]
			append(&records, body_less_decl(module, decl.name, .Signal, decl.line, decl.doc, decl.gtags, decl.todos, decl_probes_with_fields(decl.probes, decl.fields), fields_hold_stub(decl.fields), decl.exposed))
		case .Fn:
			append(&records, fn_decl_record(module, ast.fns[ref.index]))
		case .Query:
			append(&records, query_decl_record(module, ast.queries[ref.index]))
		case .Behavior:
			append(&records, behavior_decl_record(module, ast.behaviors[ref.index], typed.env, flat.routes))
		case .Pipeline:
			// A pipeline declares stage names only — no expression position, so it
			// can never hole. Its `debug` field carries its own declaration-prefix
			// probes plus every stage's @trace (decl_probes_with_stages), the §28 §4
			// On-table's stage probe position, so a stage @trace surfaces on the
			// pipeline's record.
			decl := ast.pipelines[ref.index]
			append(&records, body_less_decl(module, decl.name, .Pipeline, decl.line, decl.doc, decl.gtags, decl.todos, decl_probes_with_stages(decl.probes, decl.stages), false, decl.exposed))
		case .Let:
			decl := ast.lets[ref.index]
			append(&records, body_less_decl(module, decl.name, .Let, decl.line, decl.doc, decl.gtags, decl.todos, decl.probes, expr_holds_stub(decl.value), decl.exposed))
		case .Test:
			append(&records, test_decl_record(module, ast.tests[ref.index]))
		case .Extern_Type:
			// An opaque type owns no field default and no body (§26 §2) — no
			// expression position — so its stub verdict is constant false.
			decl := ast.extern_types[ref.index]
			append(&records, body_less_decl(module, decl.name, .Extern_Type, decl.line, decl.doc, decl.gtags, decl.todos, decl.probes, false, decl.exposed))
		}
	}

	return records[:]
}

// body_less_decl builds the Decl_Record for a body-less declaration —
// data/enum/thing/signal/pipeline/let. It carries qualified_name/kind/span/
// doc/gtags, the derived @todo flag (todo_flag over the parser's node.todos,
// §05 §2) and debug-probe names (probe_names over node.probes, §05 §5), plus
// the constant behavior-scoped (emits/consumes/calls/mut_data) fields: a
// body-less decl emits no signal, makes no call, mutates no thing, and has
// dup_class 0 (no body to hash, the gate_units extern-skip rationale). It has
// no BODY position to hole, but its expression positions (a `let`
// initializer, a field default) may carry a §15 StubExpr expression-position
// hole, so the caller derives `stub` from the kind's own expression surface
// (expr_holds_stub / fields_hold_stub / variants_hold_stub, gates.odin — the
// same walkers the release hole-ban reads). exposed is the §05 §4 @expose
// flag the parser records on the node (v5).
body_less_decl :: proc(
	module: string,
	name: string,
	kind: Index_Decl_Kind,
	span: int,
	doc: string,
	gtags: []string,
	todos: []Todo_Node,
	probes: []Debug_Probe,
	stub: bool,
	exposed: bool,
) -> Decl_Record {
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = qualify_decl(module, name),
		kind           = kind,
		file           = "",
		span           = span,
		doc            = doc,
		gtags          = gtags,
		stub           = stub,
		todo           = todo_flag(todos),
		debug          = probe_names(probes),
		exposed        = exposed,
		emits          = empty_strings(),
		consumes       = empty_strings(),
		calls          = empty_strings(),
		dup_class      = 0,
		mut_data       = empty_strings(),
	}
}

// fn_decl_record builds the Decl_Record for a top-level fn — Fn for a bodied
// fn, Extern_Fn for an `is_extern` native-boundary fn. A bodied fn carries its
// dup_class (the gate hash over its body) and its calls graph; an extern fn has
// NO body, so it carries dup_class 0 and empty calls — the same extern-skip the
// duplication gate applies so two empty bodies never collide. stub is the
// per-decl §05 §2 hole verdict over BOTH positions (fn_holds_stub, gates.odin
// — the same verdict the release hole-ban reads): a `@stub(T)` / `@stub(T,
// fallback)` body emits true, and so does an intact body carrying a §15
// StubExpr expression-position hole; an intact, hole-free (or extern) fn
// emits false. Its todo flag is the derived §05 §2
// @todo presence (todo_flag over decl.todos) and its debug field is the
// derived §05 §5 probe-name list (probe_names over decl.probes). A fn is not
// a pipeline-slot behavior, so emits/consumes/mut_data stay empty.
fn_decl_record :: proc(module: string, decl: Fn_Node) -> Decl_Record {
	kind := Index_Decl_Kind.Extern_Fn if decl.is_extern else Index_Decl_Kind.Fn
	dup: u64 = 0
	calls := empty_strings()
	if !decl.is_extern {
		dup = dup_class(decl.body)
		calls = body_calls(decl.body)
	}
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = qualify_decl(module, decl.name),
		kind           = kind,
		file           = "",
		span           = decl.line,
		doc            = decl.doc,
		gtags          = decl.gtags,
		stub           = fn_holds_stub(decl),
		todo           = todo_flag(decl.todos),
		debug          = probe_names(decl.probes),
		exposed        = decl.exposed,
		emits          = empty_strings(),
		consumes       = empty_strings(),
		calls          = calls,
		dup_class      = dup,
		mut_data       = empty_strings(),
	}
}

// query_decl_record builds the Decl_Record for a §08 §3 query declaration —
// kind Query, projected exactly as far as the §29 §2 enumeration admits. Its
// dup_class and calls come from its statement body like a bodied fn's; stub is
// the expression-position hole walk only (body_holds_stub — QueryDecl admits
// no body-position hole by grammar, fun.ebnf §7); todo/debug are the parsed
// §05 directive derivations every decl carries. A query is read-only and pure
// over (version, params) — it takes no resources and emits nothing (§08 §3) —
// so emits/consumes/mut_data are constant-empty. Its §05 §3 @index/@spatial
// requirements are deliberately NOT projected (no §29 §2 field names them).
query_decl_record :: proc(module: string, decl: Query_Node) -> Decl_Record {
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = qualify_decl(module, decl.name),
		kind           = .Query,
		file           = "",
		span           = decl.line,
		doc            = decl.doc,
		gtags          = decl.gtags,
		stub           = body_holds_stub(decl.body),
		todo           = todo_flag(decl.todos),
		debug          = probe_names(decl.probes),
		exposed        = decl.exposed,
		emits          = empty_strings(),
		consumes       = empty_strings(),
		calls          = body_calls(decl.body),
		dup_class      = dup_class(decl.body),
		mut_data       = empty_strings(),
	}
}

// behavior_decl_record builds the Decl_Record for a behavior: its dup_class and
// calls come from its reserved `step` body; its emits/consumes come from the
// §04 signal routes (the behavior at a producer endpoint emits that signal, at a
// consumer endpoint consumes it); its mut_data is its `on Thing` target when its
// step return writes that blackboard (contracts.odin). Its stub is the step's
// per-decl §05 §2 hole verdict over BOTH positions (fn_holds_stub) — a behavior
// whose reserved `step` body IS a `@stub` hole, or whose intact step body
// carries an expression-position hole, is the holed declaration the index
// reports. Its todo flag is the derived
// §05 §2 @todo presence (todo_flag over decl.todos — the behavior's own
// notes, not its step's) and its debug field is the derived §05 §5 probe-name
// list (probe_names over decl.probes — the behavior is the §28 §4 placement
// table's primary probe carrier). A behavior off every
// pipeline has no route endpoints, so its emits/consumes are empty — routes
// are the authoritative §04 projection the flatten pass already built.
behavior_decl_record :: proc(
	module: string,
	decl: Behavior_Node,
	env: Type_Env,
	routes: []Signal_Route,
) -> Decl_Record {
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = qualify_decl(module, decl.name),
		kind           = .Behavior,
		file           = "",
		span           = decl.line,
		doc            = decl.doc,
		gtags          = decl.gtags,
		stub           = fn_holds_stub(decl.step),
		todo           = todo_flag(decl.todos),
		debug          = probe_names(decl.probes),
		exposed        = decl.exposed,
		emits          = decl_behavior_emits(decl.name, routes),
		consumes       = decl_behavior_consumes(decl.name, routes),
		calls          = body_calls(decl.step.body),
		dup_class      = dup_class(decl.step.body),
		mut_data       = behavior_mut_data(decl.name, env),
	}
}

// test_decl_record builds the Decl_Record for a test block: its dup_class and
// calls come from its assert/let body. A test occupies no pipeline slot and
// mutates no thing, so emits/consumes/mut_data stay empty; its body grammar
// admits no BODY-position `@stub` hole (FnBody is a fn production, §05 §2),
// but a §15 StubExpr expression-position hole may stand in any assert/let
// expression, so stub derives from the body walk (body_holds_stub, gates.odin
// — the same walker the release hole-ban reads). The parser attaches no @todo
// notes and no @expose to a test block, so todo stays false and exposed false.
// A test is not in the §28 §4 On-table, so any probe before it is a placement
// gate refusal (the parser carries it only so the gate can name the test) — a
// valid tree's test is probe-free and its debug field is the mandatory-present
// empty.
test_decl_record :: proc(module: string, decl: Test_Node) -> Decl_Record {
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = qualify_decl(module, decl.name),
		kind           = .Test,
		file           = "",
		span           = decl.line,
		doc            = decl.doc,
		gtags          = empty_strings(),
		stub           = body_holds_stub(decl.body),
		todo           = false,
		debug          = empty_strings(),
		exposed        = false,
		emits          = empty_strings(),
		consumes       = empty_strings(),
		calls          = body_calls(decl.body),
		dup_class      = dup_class(decl.body),
		mut_data       = empty_strings(),
	}
}

// behavior_emits projects the §04 signal routes onto a behavior's emitted
// signals: a route lists the behavior at a producer endpoint iff the behavior's
// step return emits that signal list [S] (build_routes scanned the typed
// signatures over the flattened order). Routes are kept in signal-declaration
// order, so the emits list is deterministic; a behavior listed at multiple
// stages still names a signal once (a route's producer endpoints share the
// signal name).
decl_behavior_emits :: proc(name: string, routes: []Signal_Route) -> []string {
	emits := make([dynamic]string, 0, 2, context.temp_allocator)
	for route in routes {
		if endpoints_hold(route.producers, name) {
			append_unique(&emits, route.signal)
		}
	}
	return emits[:]
}

// behavior_consumes projects the §04 signal routes onto a behavior's consumed
// signals: a route lists the behavior at a consumer endpoint iff the behavior's
// step takes an inbound signal list [S] param. Routes stay in signal-declaration
// order, so the consumes list is deterministic.
decl_behavior_consumes :: proc(name: string, routes: []Signal_Route) -> []string {
	consumes := make([dynamic]string, 0, 2, context.temp_allocator)
	for route in routes {
		if endpoints_hold(route.consumers, name) {
			append_unique(&consumes, route.signal)
		}
	}
	return consumes[:]
}

// endpoints_hold reports whether any routing endpoint names the behavior — the
// per-route membership test behavior_emits/consumes run. A linear scan over the
// (small, order-fixed) endpoint slice, so the verdict never depends on map order.
endpoints_hold :: proc(endpoints: []Signal_Endpoint, name: string) -> bool {
	for endpoint in endpoints {
		if endpoint.behavior == name {
			return true
		}
	}
	return false
}

// behavior_mut_data derives the data/thing a behavior mutates: its `on Thing`
// target, reported iff its step return WRITES that blackboard (contracts.odin
// writes_own_blackboard over the unwrapped write position). A behavior whose
// return does not write its own thing (a pure emitter, a render projection)
// mutates nothing, so mut_data is empty. The target is read from the resolved
// term (the same window the contract node check reads); a behavior with no
// recorded signature contributes nothing.
behavior_mut_data :: proc(name: string, env: Type_Env) -> []string {
	term, found := env_term_name(env, name)
	if !found || term.signature == nil {
		return empty_strings()
	}
	if !writes_own_blackboard(write_of_return(term.signature.result), term.target) {
		return empty_strings()
	}
	// The target is the behavior's `on Thing` blackboard. An empty target means
	// the resolver could not ground the slot (writes_own_blackboard accepted any
	// thing write conservatively); with no concrete thing name there is nothing
	// to report, so mut_data stays empty.
	if term.target == "" {
		return empty_strings()
	}
	mut := make([]string, 1, context.temp_allocator)
	mut[0] = term.target
	return mut
}

// body_calls collects the callee identifier names of every Call_Expr reachable
// in a declaration body, deduped in first-seen order (spec §29 §2 calls graph).
// A callee is named only when it is a bare Name_Expr (a free-function call
// `clamp(…)`) or a Member_Expr (a method/associated call `body.apply_impulse(…)`,
// `Fixed.max(…)`) — the member NAME is the callee. A constructor-style call
// whose callee is neither (a record/variant head) contributes no name. First-seen
// order over the structural walk is deterministic — no map, no sort.
body_calls :: proc(body: []Statement) -> []string {
	calls := make([dynamic]string, 0, 8, context.temp_allocator)
	calls_walk_body(body, &calls)
	return calls[:]
}

// calls_walk_body folds the calls walk over a statement body, descending an `if`
// guard's condition and its nested block so a call under an early-return guard is
// still collected.
calls_walk_body :: proc(body: []Statement, calls: ^[dynamic]string) {
	for stmt in body {
		switch s in stmt {
		case Let_Node:
			calls_walk_expr(s.value, calls)
		case Assert_Node:
			calls_walk_expr(s.expr, calls)
		case Return_Node:
			calls_walk_expr(s.value, calls)
		case If_Node:
			calls_walk_expr(s.cond, calls)
			calls_walk_body(s.body, calls)
		}
	}
}

// calls_walk_expr descends an expression, recording each Call_Expr's callee name
// (when it is a bare name or a member selector) and recursing every
// sub-expression that can host a nested call. It mirrors the Expr union arm-for-arm
// so a new expression form is a visible compile gap here, not a silently-unwalked
// branch — the same totality the gate walks (gates.odin) keep.
calls_walk_expr :: proc(expr: Expr, calls: ^[dynamic]string) {
	switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr, ^All_Expr:
		// Leaf atoms host no call (`all[T]` is a world read, not an edge of the
		// §29 §2 calls graph).
	case ^Call_Expr:
		if name, ok := callee_name(e.callee); ok {
			append_unique(calls, name)
		}
		// The callee subtree itself can host further calls (a curried/chained
		// call whose callee is another call), so it is still walked.
		calls_walk_expr(e.callee, calls)
		for arg in e.args {
			calls_walk_expr(arg, calls)
		}
	case ^Member_Expr:
		calls_walk_expr(e.receiver, calls)
	case ^Variant_Expr:
		for arg in e.payload {
			calls_walk_expr(arg, calls)
		}
		for field in e.fields {
			calls_walk_expr(field.value, calls)
		}
	case ^Record_Expr:
		for field in e.fields {
			calls_walk_expr(field.value, calls)
		}
	case ^List_Expr:
		for element in e.elements {
			calls_walk_expr(element, calls)
		}
	case ^Lambda_Expr:
		calls_walk_expr(e.body, calls)
	case ^Unary_Expr:
		calls_walk_expr(e.operand, calls)
	case ^Binary_Expr:
		calls_walk_expr(e.lhs, calls)
		calls_walk_expr(e.rhs, calls)
	case ^With_Expr:
		calls_walk_expr(e.base, calls)
		for field in e.fields {
			calls_walk_expr(field.value, calls)
		}
	case ^Match_Expr:
		calls_walk_expr(e.scrutinee, calls)
		for arm in e.arms {
			calls_walk_expr(arm.body, calls)
		}
	case ^Tuple_Expr:
		for element in e.elements {
			calls_walk_expr(element, calls)
		}
	case ^If_Expr:
		calls_walk_expr(e.cond, calls)
		calls_walk_expr(e.then_branch, calls)
		calls_walk_expr(e.else_branch, calls)
	case ^Stub_Expr:
		// A §05 §2 expression hole's fallback approximation runs in dev, so a
		// call inside it is a real edge of the §29 §2 calls graph; a bare hole
		// hosts no call.
		if e.has_fallback {
			calls_walk_expr(e.fallback, calls)
		}
	}
}

// callee_name names a call's callee: a bare Name_Expr is a free-function call
// (`clamp(…)`), so its name is the callee; a Member_Expr is a method/associated
// call (`body.apply_impulse(…)`, `Fixed.max(…)`), so the member SELECTOR is the
// callee name. Any other callee form (a record/variant constructor head, a call
// of a call) names no function here.
callee_name :: proc(callee: Expr) -> (name: string, ok: bool) {
	#partial switch c in callee {
	case ^Name_Expr:
		return c.name, true
	case ^Member_Expr:
		return c.member, true
	}
	return "", false
}

// qualify builds the §15 module-qualified name: "<module>.<name>" when a module
// name is present, the bare decl name when the module is "" (the single-source
// path, lore #11). It never emits a host path — the module prefix is the §15
// path-derived module, dropped when empty.
qualify_decl :: proc(module: string, name: string) -> string {
	if module == "" {
		return name
	}
	return strings.concatenate({module, ".", name}, context.temp_allocator)
}

// append_unique appends a name to a first-seen-ordered list only when it is not
// already present — the dedupe the calls/emits/consumes lists need without a map
// (a linear membership scan keeps the order deterministic and map-free).
append_unique :: proc(list: ^[dynamic]string, name: string) {
	if slice.contains(list[:], name) {
		return
	}
	append(list, name)
}

// todo_flag derives a declaration's `todo` index field from its parsed §05 §2
// notes (node.todos): true exactly when at least one `@todo("msg", window)`
// is attached. §29 §2 names `todo` as a presence flag on the decl record, so
// the derivation reports presence only — the parsed message and expiry window
// stay on the AST (projecting them into the record is a contract reshape
// behind a schema-version bump, not this derivation's call).
todo_flag :: proc(todos: []Todo_Node) -> bool {
	return len(todos) > 0
}

// probe_names derives a declaration's `debug` index field from its parsed §05
// §5 probes: one lowercase directive name per probe in authored order, NEVER
// deduped — each probe auto-registers via the index (§28 §4: the operator sees
// every outstanding probe), so a behavior carrying two @log probes reports
// "log" twice. A probe-free declaration yields the canonical mandatory-present
// empty list. The order is the parser's accumulation order (source order), so
// the field is deterministic with no map or sort.
probe_names :: proc(probes: []Debug_Probe) -> []string {
	if len(probes) == 0 {
		return empty_strings()
	}
	names := make([]string, len(probes), context.temp_allocator)
	for probe, i in probes {
		names[i] = probe_directive_name(probe.kind)
	}
	return names
}

// decl_probes_with_fields builds the per-declaration probe set a data/thing/
// signal declaration projects into its `debug` index field: its own
// declaration-prefix probes (decl.probes) FOLLOWED by every field's §05 §5
// probe (Field_Decl.probes — the §28 §4 On-table admits a @watch on a `data`
// field). The §29 §2 `debug` list is per-declaration, so a field @watch is the
// SAME declaration's residue and must surface on the data decl's record — else
// a field @watch slips through the index unseen (the §28 §4 task-registration
// mandate: the operator sees every outstanding probe). Source order is
// declaration-prefix first, then fields in declaration order — the order the
// probes appear in source. In a valid tree the declaration-prefix set is empty
// for these kinds (the §28 §4 placement gate rejects a decl-prefix probe on a
// non-behavior), so this is in practice the field-probe list; concatenating
// decl.probes keeps the derivation total and source-ordered regardless.
decl_probes_with_fields :: proc(decl_probes: []Debug_Probe, fields: []Field_Decl) -> []Debug_Probe {
	combined := make([dynamic]Debug_Probe, 0, len(decl_probes) + len(fields), context.temp_allocator)
	for probe in decl_probes {
		append(&combined, probe)
	}
	for field in fields {
		for probe in field.probes {
			append(&combined, probe)
		}
	}
	return combined[:]
}

// decl_probes_with_variant_fields is decl_probes_with_fields for an enum: an
// enum's only field positions are its struct-payload variants' fields. A
// variant field never carries a probe in a parseable tree (a variant body is
// not a `data` body, so parse_field_list rejects a field @watch there), so this
// is in practice the declaration-prefix list; it stays total so a future
// admitted variant-field probe surfaces on the enum's record without re-editing
// the derivation.
decl_probes_with_variant_fields :: proc(decl_probes: []Debug_Probe, variants: []Variant_Decl) -> []Debug_Probe {
	combined := make([dynamic]Debug_Probe, 0, len(decl_probes), context.temp_allocator)
	for probe in decl_probes {
		append(&combined, probe)
	}
	for variant in variants {
		for field in variant.fields {
			for probe in field.probes {
				append(&combined, probe)
			}
		}
	}
	return combined[:]
}

// decl_probes_with_stages builds the per-declaration probe set a pipeline
// declaration projects into its `debug` index field: its own
// declaration-prefix probes FOLLOWED by every stage's §05 §5 probe
// (Pipeline_Stage.probes — the §28 §4 On-table admits a @trace on a stage), in
// stage order. A stage @trace is the pipeline declaration's residue, so it must
// surface on the pipeline's record — else a stage @trace slips through the
// index unseen. In a valid tree the declaration-prefix set is empty (the
// placement gate rejects a decl-prefix probe on a pipeline), so this is in
// practice the stage-probe list.
decl_probes_with_stages :: proc(decl_probes: []Debug_Probe, stages: []Pipeline_Stage) -> []Debug_Probe {
	combined := make([dynamic]Debug_Probe, 0, len(decl_probes) + len(stages), context.temp_allocator)
	for probe in decl_probes {
		append(&combined, probe)
	}
	for stage in stages {
		for probe in stage.probes {
			append(&combined, probe)
		}
	}
	return combined[:]
}

// probe_directive_name maps a closed Debug_Probe_Kind onto its source-authored
// directive spelling — the lowercase name after the `@` (§05 §5) — so the
// index reports exactly the token an agent greps the source for. The switch is
// total over the closed enum; a new probe kind is a visible compile gap here.
probe_directive_name :: proc(kind: Debug_Probe_Kind) -> string {
	switch kind {
	case .Break:
		return "break"
	case .Log:
		return "log"
	case .Watch:
		return "watch"
	case .Trace:
		return "trace"
	}
	return ""
}

// empty_strings is the canonical mandatory-present empty list (spec §29 §2: an
// absent value is the empty list, never an omitted key). It is the value the
// always-empty directive fields and the behavior-scoped fields of a non-emitting
// decl carry.
empty_strings :: proc() -> []string {
	return make([]string, 0, context.temp_allocator)
}
