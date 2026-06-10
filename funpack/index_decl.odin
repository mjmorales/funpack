// Per-declaration `decl` record DERIVATION (spec §29 §2): the source-derived
// half of the Index Contract that fills the fixed Decl_Record shape
// (index_contract.odin) from the already-compiled Typed_Ast + Flattened_Pipeline.
// It is a pure projection (spec §29 §1) — fixed gate_units-style declaration
// order, no map iteration reaching output, no clock, no float — so the emitted
// NDJSON `decl` stream is byte-identical on every machine.
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
//   - stub           — the §05 §2 typed-hole flag the parser records on a
//     body-bearing fn / behavior-step (Fn_Node.holed): a `@stub(T)` /
//     `@stub(T, fallback)` body emits true. A body-less decl and a test block
//     have no body position to hole (FnBody ::= Block | StubExpr is the only
//     hole production), so they emit false.
//   - todo           — constant false: the gameplay surface does not yet
//     parse @todo, so it is a mandatory-present empty on the current tree
//     (the @todo index derivation is its own seam, alongside this one).
//   - debug          — the §05 §5 debug-probe directive names the parser
//     records on every directive-carrying declaration node (node.probes):
//     one lowercase directive name per probe ("break"/"log"/"watch"/"trace")
//     in authored order, never deduped — the §28 §4 task-registration surface
//     reports EVERY outstanding probe. [] on a probe-free decl and on a test
//     block (the parser attaches no probes to a test).
//
// Declaration ORDER is the fixed gate_units-style per-kind walk
// (data → enum → thing → signal → fn → behavior → pipeline → let → test) so the
// vector — and the emitted NDJSON — is stable across runs and machines.
package funpack

import "core:slice"
import "core:strings"

// derive_decl_records projects every source declaration of a compiled program
// onto the §29 §2 Decl_Record shape, in the fixed gate_units-style per-kind
// order, so the derived []Decl_Record is byte-deterministic. The signal routes
// (flat.routes) supply the per-behavior emits/consumes; the typed env supplies
// the behavior signatures mut_data reads; the parser nodes supply the rest. The
// module is the §15 path-derived module name — "" on the single-source path
// (lore #11), so qualified_name is the bare decl name there. Every field is
// temp-allocated like build_project_record's derived fields, so the records are
// pure projections the emitter marshals straight onto NDJSON.
derive_decl_records :: proc(module: string, typed: Typed_Ast, flat: Flattened_Pipeline) -> []Decl_Record {
	ast := typed.ast
	records := make([dynamic]Decl_Record, 0, decl_count(ast), context.temp_allocator)

	for decl in ast.datas {
		append(&records, body_less_decl(module, decl.name, .Data, decl.line, decl.doc, decl.gtags, decl.probes))
	}
	for decl in ast.enums {
		append(&records, body_less_decl(module, decl.name, .Enum, decl.line, decl.doc, decl.gtags, decl.probes))
	}
	for decl in ast.things {
		append(&records, body_less_decl(module, decl.name, .Thing, decl.line, decl.doc, decl.gtags, decl.probes))
	}
	for decl in ast.signals {
		append(&records, body_less_decl(module, decl.name, .Signal, decl.line, decl.doc, decl.gtags, decl.probes))
	}
	for decl in ast.fns {
		append(&records, fn_decl_record(module, decl))
	}
	for decl in ast.behaviors {
		append(&records, behavior_decl_record(module, decl, typed.env, flat.routes))
	}
	for decl in ast.pipelines {
		append(&records, body_less_decl(module, decl.name, .Pipeline, decl.line, decl.doc, decl.gtags, decl.probes))
	}
	for decl in ast.lets {
		append(&records, body_less_decl(module, decl.name, .Let, decl.line, decl.doc, decl.gtags, decl.probes))
	}
	for decl in ast.tests {
		append(&records, test_decl_record(module, decl))
	}

	return records[:]
}

// decl_count is the total declaration count across every per-kind AST slice —
// the exact capacity for the records vector, so the projection makes no extra
// allocations.
decl_count :: proc(ast: Ast) -> int {
	return(
		len(ast.datas) +
		len(ast.enums) +
		len(ast.things) +
		len(ast.signals) +
		len(ast.fns) +
		len(ast.behaviors) +
		len(ast.pipelines) +
		len(ast.lets) +
		len(ast.tests) \
	)
}

// body_less_decl builds the Decl_Record for a body-less declaration —
// data/enum/thing/signal/pipeline/let. It carries qualified_name/kind/span/
// doc/gtags, the derived debug-probe names (probe_names over the parser's
// node.probes, §05 §5), plus the constant directive and behavior-scoped
// (emits/consumes/calls/mut_data) fields: a body-less decl has no body
// position to hole (so stub is false, §05 §2), carries no @todo (the parser
// does not yet admit it), emits no signal, makes no call, mutates no thing,
// and has dup_class 0 (no body to hash, the gate_units extern-skip rationale).
body_less_decl :: proc(
	module: string,
	name: string,
	kind: Index_Decl_Kind,
	span: int,
	doc: string,
	gtags: []string,
	probes: []Debug_Probe,
) -> Decl_Record {
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = qualify_decl(module, name),
		kind           = kind,
		file           = "",
		span           = span,
		doc            = doc,
		gtags          = gtags,
		stub           = false,
		todo           = false,
		debug          = probe_names(probes),
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
// duplication gate applies so two empty bodies never collide. stub reads the
// parser's holed flag (§05 §2): a `@stub(T)` / `@stub(T, fallback)` body emits
// true, an intact (or extern) fn false. Its debug field is the derived §05 §5
// probe-name list (probe_names over decl.probes). A fn is not a pipeline-slot
// behavior, so emits/consumes/mut_data stay empty.
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
		stub           = decl.holed,
		todo           = false,
		debug          = probe_names(decl.probes),
		emits          = empty_strings(),
		consumes       = empty_strings(),
		calls          = calls,
		dup_class      = dup,
		mut_data       = empty_strings(),
	}
}

// behavior_decl_record builds the Decl_Record for a behavior: its dup_class and
// calls come from its reserved `step` body; its emits/consumes come from the
// §04 signal routes (the behavior at a producer endpoint emits that signal, at a
// consumer endpoint consumes it); its mut_data is its `on Thing` target when its
// step return writes that blackboard (contracts.odin). Its stub reads the step's
// holed flag (§05 §2) — a behavior whose reserved `step` body is a `@stub` hole
// is the holed declaration the index reports. Its debug field is the derived
// §05 §5 probe-name list (probe_names over decl.probes — the behavior is the
// §28 §4 placement table's primary probe carrier). A behavior off every
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
		stub           = decl.step.holed,
		todo           = false,
		debug          = probe_names(decl.probes),
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
// admits no `@stub` hole (only fn bodies do, §05 §2), so stub stays false, and
// the parser attaches no debug probes to a test block, so debug stays [].
test_decl_record :: proc(module: string, decl: Test_Node) -> Decl_Record {
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = qualify_decl(module, decl.name),
		kind           = .Test,
		file           = "",
		span           = decl.line,
		doc            = decl.doc,
		gtags          = empty_strings(),
		stub           = false,
		todo           = false,
		debug          = empty_strings(),
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
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr:
		// Leaf atoms host no call.
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
