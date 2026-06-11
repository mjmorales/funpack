// Evaluator over tagged Values and the saturating scalar kernel.
// Every operation is total and all-integer (spec §10) — no epsilon, no
// float, bit-identical on every machine. eval_expr fails closed: a form
// outside the evaluable domain returns ok = false, and the typecheck
// gate keeps such forms from reaching a counted assert. Each test block
// owns an environment frame; let statements bind into it in statement
// order, and lambda applications chain child frames off the captured
// env so iterations never leak bindings.
//
// The §06/§07 gameplay surface evaluates against the resolved module: a
// test calls user top-level fns by their recorded signature, invokes a
// behavior's `step` in test position (the §04 name.step(args) form), and
// constructs/compares user records and enum variants. Eval_Ctx threads the
// typed module (its fn/behavior/enum/record schemas) through evaluation so
// those forms resolve; the numeric kernel forms ignore it.
package funpack

import "core:slice"
import "core:strings"

// Env is a chained binding frame. Lookups walk toward the root; only
// the owning scope ever inserts, and nothing iterates the map — map
// order can never reach evaluation results (the determinism tripwire).
Env :: struct {
	bindings: map[string]Value,
	parent:   ^Env,
}

// Eval_Ctx carries the resolved module through evaluation: ast supplies the
// user fn/behavior bodies and the module-level `let` constants, env the
// declared record/enum schemas (resolve.odin). bindings is the module's own
// imported-name resolutions (surface.odin) — read only to recover the OWNING
// module of a whole-module handle (`assets`) when a test evaluates a cross-module
// const (`assets.coin_sfx`). modules is the project-wide eval surface: one entry
// per sibling user module, so a module-qualified const evaluates its initializer
// in its OWNING module's environment. It is read-only — evaluation never mutates
// it — and is threaded alongside the per-call binding frame so a user fn call or
// a name.step invocation reaches the body to execute. In the single-source path
// bindings is empty and modules is nil, so the cross-module arm never fires.
//
// module is this ctx's own §15 module name — the namespace half of a const's
// cycle key (`module.const`). It is empty in the single-source path (no project
// module name) and set to the owning module when the cross-module arm builds a
// fresh ctx, so a const that reaches back to its origin keys the same entry.
// visiting is the const-resolution cycle guard, threaded by pointer so the ONE
// set is shared across every by-value Eval_Ctx copy (including the cross-module
// owner_ctx): a const whose initializer transitively reaches itself registers
// its key on entry and trips the guard on revisit, failing closed (ok = false)
// instead of recursing to a stack overflow (spec §10 totality).
Eval_Ctx :: struct {
	ast:           Ast,
	env:           Type_Env,
	bindings:      Bindings,
	modules:       []Module_Eval,
	module:        string,
	visiting:      ^Const_Visit,
	// query_indexes is the ENCLOSING §08 §3 query's declared @index/@spatial
	// requirement set — set by the eval_user_fn dispatch when the callable is
	// a query (find_user_callable carries it), cleared for every fn/behavior
	// frame — so the spatial combinators resolve the field they measure from
	// the declaration that admitted them (spatial_combinator_check's rule).
	query_indexes: []Index_Directive,
}

// Const_Visit is the const-resolution visited set: the module-qualified names
// (`module.const`) currently mid-evaluation on the active initializer chain. A
// const enters its key before evaluating its RHS and removes it after, so the
// set holds exactly the chain in progress; reaching a key already present is a
// const-initializer cycle. It is a map only for O(1) membership — never iterated
// (the determinism tripwire), so map order never reaches an evaluation result.
// Shared by pointer across every Eval_Ctx so the intra-module and cross-module
// const paths consult ONE set.
Const_Visit :: struct {
	active: map[string]bool,
}

// Module_Eval is one sibling user module's evaluation surface: its §15 module
// name plus the resolved (ast, env, bindings) triple a cross-module const
// reference evaluates against. A module-qualified const (`assets.coin_sfx`) builds
// a fresh Eval_Ctx over the OWNING module's triple and evaluates the let
// initializer there — the value the seam emits, in the environment that declares
// it. Walked by index (module_eval_lookup), never iterated — the determinism
// tripwire mirrored from Module_Index.
Module_Eval :: struct {
	module:   string,
	ast:      Ast,
	env:      Type_Env,
	bindings: Bindings,
	modules:  []Module_Eval, // shared back-reference so a const RHS can itself reach a sibling
}

new_env :: proc(parent: ^Env) -> ^Env {
	env := new(Env, context.temp_allocator)
	env.bindings = make(map[string]Value, context.temp_allocator)
	env.parent = parent
	return env
}

env_lookup :: proc(env: ^Env, name: string) -> (value: Value, ok: bool) {
	for frame := env; frame != nil; frame = frame.parent {
		if v, found := frame.bindings[name]; found {
			return v, true
		}
	}
	return nil, false
}

stage_evaluate :: proc(typed: Typed_Ast) -> Eval_Result {
	return stage_evaluate_indexed(typed, nil, "")
}

// stage_evaluate_indexed evaluates one module's tests against a project-wide eval
// surface, so a test reaching a cross-module const (`assets.coin_sfx`) evaluates
// the const in its owning module's environment. modules = nil reduces it to the
// single-source stage_evaluate — the cross-module arm in eval_member never fires —
// so every existing single-module test path is unchanged. The consumer's own
// bindings thread in (eval_member recovers a handle's owning module from them).
// module is this module's §15 name, the namespace half of an intra-module const's
// cycle key (empty in the single-source path). A fresh Const_Visit is allocated
// per stage run and shared by pointer through the ctx, so a const cycle reachable
// from any test trips the guard rather than overflowing the stack.
stage_evaluate_indexed :: proc(typed: Typed_Ast, modules: []Module_Eval, module: string) -> Eval_Result {
	result := Eval_Result{}
	visit := new(Const_Visit, context.temp_allocator)
	visit.active = make(map[string]bool, context.temp_allocator)
	ctx := Eval_Ctx {
		ast      = typed.ast,
		env      = typed.env,
		bindings = typed.bindings,
		modules  = modules,
		module   = module,
		visiting = visit,
	}
	for test in typed.ast.tests {
		env := new_env(nil)
		for stmt in test.body {
			switch node in stmt {
			case Let_Node:
				// A failed RHS leaves the name unbound; the asserts
				// reading it then fail rather than trapping.
				if value, ok := eval_expr(ctx, env, node.value); ok {
					env.bindings[node.name] = value
				}
			case Assert_Node:
				if eval_assert(ctx, env, node) {
					result.passed += 1
				} else {
					result.failed += 1
				}
			case Return_Node, If_Node:
				// Return/If are fn-body statements; a test block never holds
				// them, so the evaluator skips them.
			}
		}
	}
	return result
}

// eval_assert passes only when the expression evaluates to Bool true.
eval_assert :: proc(ctx: Eval_Ctx, env: ^Env, node: Assert_Node) -> bool {
	value, ok := eval_expr(ctx, env, node.expr)
	if !ok {
		return false
	}
	passed, is_bool := value.(bool)
	return is_bool && passed
}

eval_expr :: proc(ctx: Eval_Ctx, env: ^Env, expr: Expr) -> (value: Value, ok: bool) {
	#partial switch e in expr {
	case ^Int_Lit_Expr:
		return e.value, true
	case ^Fixed_Lit_Expr:
		return e.bits, true
	case ^String_Lit_Expr:
		// A string literal evaluates to its raw inner text — the §19 asset name a
		// handle constructor (sound("coin_sfx")) or a handle literal (SoundHandle{
		// name: "coin_sfx"}) keys on. Interpolation holes are retained verbatim
		// (a lowering concern, not evaluation), matching the parse-only `text`.
		return e.text, true
	case ^Name_Expr:
		// §02 §2 Bool literals resolve before the environment, mirroring
		// name_check — they are keywords, never shadowable bindings.
		if e.name == "true" {
			return true, true
		}
		if e.name == "false" {
			return false, true
		}
		if bound, found := env_lookup(env, e.name); found {
			return bound, true
		}
		// A module-level `let` constant is a value name resolved through the
		// module (BOARD), evaluated against an empty frame — a constant's RHS
		// reads no local binding.
		if constant, declared := eval_module_const(ctx, e.name); declared {
			return constant, true
		}
		// The sanctioned lowercase constants are the builtin fallback (spec §02:
		// pi/tau are the only snake_case constant exceptions; §10: the nearest-Fixed
		// angle constants). advance_gait wraps its phase into [0, tau) with `% tau`.
		if e.name == "pi" {
			return PI_FIXED, true
		}
		if e.name == "tau" {
			return TAU_FIXED, true
		}
		return nil, false
	case ^Unary_Expr:
		return eval_unary(ctx, env, e)
	case ^Binary_Expr:
		return eval_binary(ctx, env, e)
	case ^Member_Expr:
		return eval_member(ctx, env, e)
	case ^Call_Expr:
		return eval_call(ctx, env, e)
	case ^Variant_Expr:
		return eval_variant(ctx, env, e)
	case ^Record_Expr:
		return eval_record(ctx, env, e)
	case ^List_Expr:
		return eval_list(ctx, env, e)
	case ^Tuple_Expr:
		return eval_tuple(ctx, env, e)
	case ^With_Expr:
		return eval_with(ctx, env, e)
	case ^Match_Expr:
		return eval_match(ctx, env, e)
	case ^If_Expr:
		return eval_if(ctx, env, e)
	case ^Lambda_Expr:
		return Lambda_Value{node = e, env = env}, true
	case ^Stub_Expr:
		// A §05 §2 expression-position hole evaluates through the same funnel
		// as a body-position hole: the fallback approximation runs in the
		// CURRENT frame (the scope at the hole's position), and a bare hole is
		// the defined fail-closed no-value outcome — ok = false propagates up,
		// so the assert reading the enclosing expression fails counted, never
		// a trap.
		return eval_stub_hole(ctx, env, e.fallback, e.has_fallback)
	case ^All_Expr:
		return eval_all(ctx, e)
	}
	return nil, false
}

// eval_all materializes the §08 §3 world read `all[T]` in the TEST
// interpreter: the world here is the module's startup population — the
// setup() spawn batch (resolve_setup_spawns, the same §13 batch the runtime
// seeds its version 0 from) — so a query body reads exactly the rows the
// runtime's tick 0 would hold, and the two interpreters agree on the read. A
// module with no setup() (or one spawning no T) reads the empty table. Rows
// materialize in SPAWN ORDER, which IS stable Id order (the deterministic
// spawn counter assigns Ids in batch order), so fold/first and the
// nearest-first tiebreak over this list match the runtime's Id-ordered View.
// The result is a List_Value — the same materialized shape a View.of fixture
// and the runtime's View param binding take — so every list combinator
// composes over it unchanged.
eval_all :: proc(ctx: Eval_Ctx, e: ^All_Expr) -> (value: Value, ok: bool) {
	thing, declared := thing_by_name(ctx.ast, e.thing)
	if !declared {
		return nil, false
	}
	spawns := resolve_setup_spawns(ctx.ast)
	rows := make([dynamic]Value, 0, len(spawns), context.temp_allocator)
	for spawn in spawns {
		if spawn.type_name != e.thing {
			continue
		}
		row := eval_spawn_row(ctx, thing, spawn) or_return
		append(&rows, row)
	}
	return List_Value{elements = rows[:]}, true
}

// eval_spawn_row lifts one resolved setup spawn into the Record_Value a
// query's world read iterates: every declared field of the thing's schema, in
// SCHEMA ORDER, valued by the spawn's authored expression when present and by
// the field's declared default otherwise — the same overlay the runtime's
// row decoder applies, so a row reads identically on both sides. A field the
// spawn omits with no declared default fails closed (ok = false) — a partial
// row is never a defined read.
eval_spawn_row :: proc(ctx: Eval_Ctx, thing: Thing_Node, spawn: Resolved_Spawn) -> (value: Value, ok: bool) {
	frame := new_env(nil)
	fields := make([]Record_Field_Value, len(thing.fields), context.temp_allocator)
	for field, i in thing.fields {
		source, authored := spawn_field_expr(spawn, field.name)
		if !authored {
			if !field.has_default {
				return nil, false
			}
			source = field.default
		}
		field_value := eval_expr(ctx, frame, source) or_return
		fields[i] = Record_Field_Value{name = field.name, value = field_value}
	}
	return Record_Value{type_name = thing.name, fields = fields}, true
}

// spawn_field_expr reads one authored field expression off a resolved spawn —
// a linear scan over the source-ordered field list, the determinism-stable
// lookup every schema overlay here uses.
spawn_field_expr :: proc(spawn: Resolved_Spawn, name: string) -> (expr: Expr, authored: bool) {
	for field in spawn.fields {
		if field.name == name {
			return field.value, true
		}
	}
	return nil, false
}

// eval_if evaluates a value-producing if-expression (spec §02 §5): the
// condition evaluates to a Bool, then exactly one arm evaluates and yields the
// if-expression's value — the consequent when true, the alternate when false.
// Both arms are present (the parser requires `else`) and unify (the
// typechecker), so a false guard always has an alternate to take. A non-Bool
// condition is a fail-closed ok = false — a typecheck-rejected shape that never
// reaches a passing program.
eval_if :: proc(ctx: Eval_Ctx, env: ^Env, e: ^If_Expr) -> (value: Value, ok: bool) {
	cond := eval_expr(ctx, env, e.cond) or_return
	guard, is_bool := cond.(bool)
	if !is_bool {
		return nil, false
	}
	if guard {
		return eval_expr(ctx, env, e.then_branch)
	}
	return eval_expr(ctx, env, e.else_branch)
}

eval_list :: proc(ctx: Eval_Ctx, env: ^Env, e: ^List_Expr) -> (value: Value, ok: bool) {
	elements := make([]Value, len(e.elements), context.temp_allocator)
	for element, i in e.elements {
		elements[i] = eval_expr(ctx, env, element) or_return
	}
	return List_Value{elements = elements}, true
}

// eval_tuple lowers a tuple literal `(a, b, …)` (spec §02; §04 §1): each position
// evaluates in source order into a positional Tuple_Value — the `(value,
// next_rng)` / `(Option, Rng)` shape a draw/startup returns and a tuple-pattern
// match destructures.
eval_tuple :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Tuple_Expr) -> (value: Value, ok: bool) {
	elements := make([]Value, len(e.elements), context.temp_allocator)
	for element, i in e.elements {
		elements[i] = eval_expr(ctx, env, element) or_return
	}
	return Tuple_Value{elements = elements}, true
}

// apply_lambda binds the parameters in a fresh child frame off the
// captured environment, so applications are isolated from one another.
apply_lambda :: proc(ctx: Eval_Ctx, lambda: Lambda_Value, args: []Value) -> (value: Value, ok: bool) {
	if len(args) != len(lambda.node.params) {
		return nil, false
	}
	frame := new_env(lambda.env)
	for param, i in lambda.node.params {
		frame.bindings[param] = args[i]
	}
	return eval_expr(ctx, frame, lambda.node.body)
}

// eval_module_const evaluates a module-level `let NAME = expr` constant
// (resolve.odin records it as a Const term). The RHS reads no local binding,
// so it evaluates against a fresh root frame; a name that is not a declared
// const returns declared = false for the caller to fall through.
//
// A const-initializer cycle (`let a = b` / `let b = a`, or a self-reference)
// is caught fail-closed: the const's module-qualified key registers in the
// shared visited set before its RHS evaluates and clears after, so reaching a
// key already on the active chain returns declared = false WITHOUT recursing —
// the assert reading the cyclic const then fails (a counted failure), instead
// of the unbounded recursion that would overflow the stack. declared stays true
// only for a const that genuinely resolves to a value; the revisit is reported
// as undeclared so the caller's fall-through arms (builtins) still run and the
// reader fails on a missing binding, the same fail-closed shape a const whose
// RHS does not evaluate already takes (spec §10 totality, the closed-error
// discipline: no panic, no partial value).
eval_module_const :: proc(ctx: Eval_Ctx, name: string) -> (value: Value, declared: bool) {
	if term, found := env_term_name(ctx.env, name); !found || term.kind != .Const {
		return nil, false
	}
	for decl in ctx.ast.lets {
		if decl.name == name {
			key := const_cycle_key(ctx.module, name)
			if ctx.visiting != nil && ctx.visiting.active[key] {
				// Already mid-evaluation on the active chain — a cycle. Fail
				// closed: the reader sees an undeclared const and fails its
				// assert, never the recursion that would overflow the stack.
				return nil, false
			}
			if ctx.visiting != nil {
				ctx.visiting.active[key] = true
			}
			v, ok := eval_expr(ctx, new_env(nil), decl.value)
			if ctx.visiting != nil {
				delete_key(&ctx.visiting.active, key)
			}
			return v, ok
		}
	}
	return nil, false
}

// const_cycle_key is the visited-set key for a const: its §15 module name dotted
// with the const name (`module.const`), so the SAME const has the SAME key whether
// it is reached by bare name in its own module or cross-module through a handle, and
// two modules' like-named consts never collide. An empty module (the single-source
// path) keys as `.const`, still unique within that one module.
const_cycle_key :: proc(module: string, name: string) -> string {
	return strings.concatenate({module, ".", name}, context.temp_allocator)
}

// eval_user_fn evaluates a top-level user fn or a behavior's `step` body
// against its arguments (spec §06 §3): the params bind in a fresh root frame
// (a fn body is a closed scope — it reads only its params and module-level
// constants), then the statement sequence runs to its `return`. ok = false
// when the body produces no value (a body with no reachable return is a
// typecheck-rejected shape that never reaches here). A holed decl (spec §05
// §2) has no statement sequence at all — eval_stub_hole stands in for the
// body walk, mirroring check_stub_hole on the typing side.
eval_user_fn :: proc(ctx: Eval_Ctx, fn: Fn_Node, args: []Value) -> (value: Value, ok: bool) {
	if len(args) != len(fn.params) {
		return nil, false
	}
	frame := new_env(nil)
	for param, i in fn.params {
		frame.bindings[param.name] = args[i]
	}
	if fn.holed {
		return eval_stub_hole(ctx, frame, fn.fallback, fn.has_fallback)
	}
	return eval_statements(ctx, frame, fn.body)
}

// eval_stub_hole runs a typed hole reached at evaluation time (spec §05 §2,
// P8: the approximation keeps the game playable) — the single eval-side
// funnel for BOTH hole positions: a body-position hole reaches it from
// eval_user_fn, an expression-position StubExpr Atom from eval_expr. A
// `@stub(T, fallback)` hole evaluates its fallback expression in the frame at
// the hole's position — the declaration's param-seeded frame for a body hole,
// the surrounding scope for an expression hole — so a fallback reading a
// parameter (`@stub(Ball, b)`) returns the argument; the typecheck side
// (check_stub_hole / stub_expr_check) already typed the fallback against the
// hole's T in that same scope, so the value is type-sound. A typecheck-only
// `@stub(T)` has nothing to run: it is dev-anchoring only and never ships
// (the release gate refuses it), so reaching one is the evaluator's defined
// fail-closed no-value outcome — the assert (or enclosing expression) reading
// it fails counted, never a trap.
eval_stub_hole :: proc(ctx: Eval_Ctx, frame: ^Env, fallback: Expr, has_fallback: bool) -> (value: Value, ok: bool) {
	if has_fallback {
		return eval_expr(ctx, frame, fallback)
	}
	return nil, false
}

// eval_statements runs a fn-body statement sequence to its return value: a let
// binds into the frame, an `if cond { return … }` early-return fires its body
// when the guard is true, and a `return expr` yields. The first return reached
// is the body's value; reaching the end with no return is ok = false.
eval_statements :: proc(ctx: Eval_Ctx, frame: ^Env, body: []Statement) -> (value: Value, ok: bool) {
	for stmt in body {
		switch node in stmt {
		case Let_Node:
			v := eval_expr(ctx, frame, node.value) or_return
			frame.bindings[node.name] = v
		case If_Node:
			cond := eval_expr(ctx, frame, node.cond) or_return
			guard, is_bool := cond.(bool)
			if !is_bool {
				return nil, false
			}
			if guard {
				return eval_statements(ctx, frame, node.body)
			}
		case Return_Node:
			return eval_expr(ctx, frame, node.value)
		case Assert_Node:
			// An assert is a test-block statement; a fn body never holds one.
		}
	}
	return nil, false
}

// eval_variant lowers an enum-variant value: Option::Some/None (the
// evaluable Option family), a bare engine enum variant (Color::White,
// Side::Left is a user enum below), a struct-payload engine command
// (Draw::Rect{…}), or a bare user enum variant. Option is special-cased for
// its payload box; every other bare variant lowers to an Enum_Value.
eval_variant :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Variant_Expr) -> (value: Value, ok: bool) {
	if e.type_name == "Option" {
		return eval_option_variant(ctx, env, e)
	}
	if e.has_fields {
		// A struct-payload engine command variant (Draw::Rect{at, size, color}).
		return eval_struct_variant(ctx, env, e)
	}
	if e.has_payload {
		// A §21 §3 tagged-union construction: AppMsg::Hud(HudMsg::Coin),
		// SettingsMsg::SetVolume(50). The surface carries exactly one payload per
		// variant; the argument evaluates and is boxed onto the Enum_Value.
		if len(e.payload) != 1 {
			return nil, false
		}
		inner := eval_expr(ctx, env, e.payload[0]) or_return
		boxed := new(Value, context.temp_allocator)
		boxed^ = inner
		return Enum_Value{type_name = e.type_name, variant = e.variant, payload = boxed}, true
	}
	// A bare variant value — a nullary user enum (Side::Left, HudMsg::Coin) or an
	// engine enum (Color::White, Bus::Ui). Both lower to the same (type_name,
	// variant) tag with no payload. (A payload variant named WITHOUT its payload
	// is the §21 §3 variant-as-function value, reached only in a `view` body the
	// asserts never evaluate, so it is left to the fail-closed path.)
	return Enum_Value{type_name = e.type_name, variant = e.variant}, true
}

// eval_option_variant lowers Option::Some(v)/Option::None — the boxed Option
// family the numeric kernel and the match arms read.
eval_option_variant :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Variant_Expr) -> (value: Value, ok: bool) {
	switch e.variant {
	case "Some":
		if !e.has_payload || len(e.payload) != 1 {
			return nil, false
		}
		inner := eval_expr(ctx, env, e.payload[0]) or_return
		boxed := new(Value, context.temp_allocator)
		boxed^ = inner
		return Option_Value{is_some = true, payload = boxed}, true
	case "None":
		if e.has_payload {
			return nil, false
		}
		return Option_Value{is_some = false, payload = nil}, true
	}
	return nil, false
}

// eval_struct_variant constructs a struct-payload engine command value
// (Draw::Rect{at, size, color}): each named field evaluates and the result is
// a variant-tagged Record_Value the equality compares structurally.
eval_struct_variant :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Variant_Expr) -> (value: Value, ok: bool) {
	fields := make([]Record_Field_Value, len(e.fields), context.temp_allocator)
	for field, i in e.fields {
		v := eval_expr(ctx, env, field.value) or_return
		fields[i] = Record_Field_Value{name = field.name, value = v}
	}
	return Record_Value{type_name = e.type_name, variant = e.variant, fields = fields}, true
}

// eval_record lowers a record literal: Vec2/Vec3 onto the component slots, and
// a user thing/data/signal literal into a Record_Value carrying its evaluated
// fields. A user literal may omit a defaulted field (spec §03 §1), so the
// declared defaults fill any field the literal did not name.
eval_record :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Record_Expr) -> (value: Value, ok: bool) {
	switch e.type_name {
	case "Vec2":
		v := Vec2_Value{}
		for field in e.fields {
			component := eval_expr(ctx, env, field.value) or_return
			f := component.(Fixed) or_return
			switch field.name {
			case "x":
				v.x = f
			case "y":
				v.y = f
			case:
				return nil, false
			}
		}
		return v, true
	case "Vec3":
		v := Vec3_Value{}
		for field in e.fields {
			component := eval_expr(ctx, env, field.value) or_return
			f := component.(Fixed) or_return
			switch field.name {
			case "x":
				v.x = f
			case "y":
				v.y = f
			case "z":
				v.z = f
			case:
				return nil, false
			}
		}
		return v, true
	}
	if record, declared := ctx.env.records[e.type_name]; declared {
		return eval_user_record(ctx, env, e, record)
	}
	// A CROSS-MODULE user record literal (spec §15: every top-level declaration is
	// importable) — SettingsPresetRow{value: 50} / PauseView{} built from a seam's
	// imported `data`. The record's schema + declared defaults live in the OWNING
	// module's env/ast, so the literal resolves through the cross-module eval
	// surface, mirroring eval_module_qualified_const. The literal's named field
	// VALUES are consumer expressions (the `50` is this test's), so they evaluate in
	// the CONSUMER ctx; only the omitted defaults come from the owner.
	if crossmod_value, crossmod_ok, is_crossmod := eval_module_record(ctx, env, e); is_crossmod {
		return crossmod_value, crossmod_ok
	}
	// A §19 typed asset-handle literal (MeshHandle{name: "coin"}, SoundHandle{name:
	// "coin_sfx"}): the only engine records the evaluator constructs — each named
	// field evaluates into a tagged Record_Value carrying the handle's type name, so
	// the typed seam constant compares equal to the string-constructor handle of the
	// same name (the §19 golden's assets.coin_sfx == sound("coin_sfx")). Reached only
	// for a handle name (surface_engine_record's handle arms); a non-handle engine
	// record (Body, Save) never reaches construction in test position.
	if _, _, is_handle := surface_engine_record(e.type_name); is_handle && is_asset_handle_name(e.type_name) {
		return eval_asset_handle_literal(ctx, env, e)
	}
	return nil, false
}

// is_asset_handle_name reports whether `name` is one of the §19/§26 typed
// asset handle records — the closed set the evaluator constructs as literals:
// the four engine.assets handles plus the §18 §2/§3 engine.tilemap handles
// the .tiles and level seam constants bind (TilesetHandle / TilemapHandle).
// surface_engine_record also schemas Body/Save/etc., which the evaluator does
// not build in test position, so the handle set is named explicitly here
// rather than constructing every engine record.
is_asset_handle_name :: proc(name: string) -> bool {
	switch name {
	case "MeshHandle", "TextureHandle", "SoundHandle", "AtlasHandle", "TilesetHandle", "TilemapHandle":
		return true
	}
	return false
}

// eval_asset_handle_literal builds a typed asset-handle value from its literal:
// each named field evaluates and the result is a Record_Value tagged with the
// handle's type name (no variant). A handle's one field is its String `name`, so
// the value is the handle-typed record the equality compares structurally against
// the string-constructor handle of the same name.
eval_asset_handle_literal :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Record_Expr) -> (value: Value, ok: bool) {
	fields := make([]Record_Field_Value, len(e.fields), context.temp_allocator)
	for field, i in e.fields {
		v := eval_expr(ctx, env, field.value) or_return
		fields[i] = Record_Field_Value{name = field.name, value = v}
	}
	return Record_Value{type_name = e.type_name, fields = fields}, true
}

// eval_user_record builds a user thing/data/signal value: every field the
// literal names evaluates, then each defaulted field the literal omitted is
// filled from its declared default expression (spec §03 §1). The result is a
// plain (untagged) Record_Value carrying one slot per schema field.
eval_user_record :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Record_Expr, schema: Record_Schema) -> (value: Value, ok: bool) {
	fields := make([dynamic]Record_Field_Value, 0, len(schema.fields), context.temp_allocator)
	for field in e.fields {
		v := eval_expr(ctx, env, field.value) or_return
		append(&fields, Record_Field_Value{name = field.name, value = v})
	}
	// Fill any defaulted schema field the literal left out, in schema order, so
	// two records of the same type carry the same field set regardless of which
	// optional fields each literal named (the Scoreboard{left, right} golden).
	for decl in record_decl_fields(ctx.ast, e.type_name) {
		if !decl.has_default {
			continue
		}
		if _, present := record_field_value(fields[:], decl.name); present {
			continue
		}
		v := eval_expr(ctx, env, decl.default) or_return
		append(&fields, Record_Field_Value{name = decl.name, value = v})
	}
	return Record_Value{type_name = e.type_name, fields = fields[:]}, true
}

// eval_module_record builds a CROSS-MODULE user record literal (spec §15: a
// declaration's module of origin is invisible at the use site) — a seam's
// imported `data` constructed in a consumer test (SettingsPresetRow{value: 50},
// PauseView{}). The record's type binds to its OWNING module (the consumer's
// .Type_Name binding), whose eval surface carries the declared field defaults; the
// literal's NAMED field values are consumer expressions, so they evaluate in the
// CONSUMER ctx/env, while each omitted default evaluates in a fresh OWNER ctx (the
// default is an owner-module expression over owner-module names). is_crossmod =
// false when the type is not a sibling-module record, so eval_record falls through
// to its other arms. Mirrors eval_module_qualified_const for the record position.
eval_module_record :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Record_Expr) -> (value: Value, ok: bool, is_crossmod: bool) {
	binding, bound := ctx.bindings.names[e.type_name]
	if !bound || binding.kind != .Type_Name {
		return nil, false, false
	}
	owner, found := module_eval_lookup(ctx.modules, binding.module)
	if !found {
		return nil, false, false
	}
	if _, declared := owner.env.records[e.type_name]; !declared {
		return nil, false, false
	}
	owner_ctx := Eval_Ctx {
		ast      = owner.ast,
		env      = owner.env,
		bindings = owner.bindings,
		modules  = owner.modules,
		module   = binding.module,
		visiting = ctx.visiting,
	}

	fields := make([dynamic]Record_Field_Value, 0, 4, context.temp_allocator)
	for field in e.fields {
		// A named field value is the CONSUMER's expression — evaluated in the
		// consumer ctx/env, exactly as a local record literal's field is.
		v, field_ok := eval_expr(ctx, env, field.value)
		if !field_ok {
			return nil, false, true
		}
		append(&fields, Record_Field_Value{name = field.name, value = v})
	}
	// Each omitted default is an OWNER-module expression (it names owner-module
	// types/consts), so it evaluates in the owner ctx over a fresh owner env.
	owner_env := new_env(nil)
	for decl in record_decl_fields(owner.ast, e.type_name) {
		if !decl.has_default {
			continue
		}
		if _, present := record_field_value(fields[:], decl.name); present {
			continue
		}
		v, default_ok := eval_expr(owner_ctx, owner_env, decl.default)
		if !default_ok {
			return nil, false, true
		}
		append(&fields, Record_Field_Value{name = decl.name, value = v})
	}
	return Record_Value{type_name = e.type_name, fields = fields[:]}, true, true
}

// record_decl_fields returns a user record's declared field list (with the
// default expressions the schema does not retain), looked up by type name
// across the thing/data/signal declarations — the source of a literal's
// defaulted fields.
record_decl_fields :: proc(ast: Ast, type_name: string) -> []Field_Decl {
	for decl in ast.things {
		if decl.name == type_name {
			return decl.fields
		}
	}
	for decl in ast.datas {
		if decl.name == type_name {
			return decl.fields
		}
	}
	for decl in ast.signals {
		if decl.name == type_name {
			return decl.fields
		}
	}
	return nil
}

// eval_with applies a record-update `base with { field: v, … }` (spec §02 §5):
// the base evaluates to a Record_Value, then each named field is replaced by
// its new value (copy-on-write — a fresh field slice, the base untouched).
eval_with :: proc(ctx: Eval_Ctx, env: ^Env, e: ^With_Expr) -> (value: Value, ok: bool) {
	base := eval_expr(ctx, env, e.base) or_return
	record, is_record := base.(Record_Value)
	if !is_record {
		return nil, false
	}
	updated := make([]Record_Field_Value, len(record.fields), context.temp_allocator)
	copy(updated, record.fields)
	for replacement in e.fields {
		v := eval_expr(ctx, env, replacement.value) or_return
		if !record_replace_field(updated, replacement.name, v) {
			return nil, false
		}
	}
	return Record_Value{type_name = record.type_name, variant = record.variant, fields = updated}, true
}

// record_replace_field overwrites a named field's slot in place; replaced =
// false when the field is not in the record (a typecheck-rejected shape that
// never reaches evaluation).
record_replace_field :: proc(fields: []Record_Field_Value, name: string, value: Value) -> (replaced: bool) {
	for &field in fields {
		if field.name == name {
			field.value = value
			return true
		}
	}
	return false
}

// eval_match evaluates a match (spec §02 §5): the scrutinee evaluates, then the
// first arm whose pattern matches it runs its body with any payload binders
// bound in a child frame. Pattern matching covers the wildcard, a bare variant
// (user Side::Left or boxed Option::None), and a payload-binding variant
// (Option::Some(v)). Exhaustiveness is the gate's guarantee, so a scrutinee
// always matches some arm here.
eval_match :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Match_Expr) -> (value: Value, ok: bool) {
	scrutinee := eval_expr(ctx, env, e.scrutinee) or_return
	for arm in e.arms {
		frame, matched := match_pattern(arm.pattern, scrutinee, env)
		if matched {
			return eval_expr(ctx, frame, arm.body)
		}
	}
	return nil, false
}

// match_pattern tests one arm pattern against a scrutinee value and, on a
// match, returns a frame holding the pattern's payload binders. A wildcard
// always matches with no binders; a bare variant matches an Enum_Value of the
// same (type_name, variant) or the Option None tag; a payload-binding variant
// matches Option::Some or a §21 §3 user tagged-union variant and recurses into
// its one payload sub-pattern, accumulating its binders.
match_pattern :: proc(pattern: Pattern, scrutinee: Value, env: ^Env) -> (frame: ^Env, matched: bool) {
	switch pattern.kind {
	case .Wildcard:
		return env, true
	case .Bare_Variant:
		if pattern.type_name == "Option" {
			option, is_option := scrutinee.(Option_Value)
			return env, is_option && !option.is_some && pattern.variant == "None"
		}
		variant, is_variant := scrutinee.(Enum_Value)
		matched = is_variant && variant.type_name == pattern.type_name && variant.variant == pattern.variant
		return env, matched
	case .Variant_Binds:
		// The grammar carries the payload as one sub-pattern (Option::Some(v) →
		// [Bare_Binder v]; AppMsg::Hud(m) → [Bare_Binder m]; AppMsg::Hud(HudMsg::Coin)
		// → [Bare_Variant HudMsg::Coin]). Match the variant, then recurse the
		// sub-pattern against the unboxed payload value, so a binder binds and a
		// nested variant filters.
		if len(pattern.elements) != 1 {
			return env, false
		}
		payload: Value
		if option, is_option := scrutinee.(Option_Value); is_option {
			if !option.is_some || pattern.variant != "Some" {
				return env, false
			}
			payload = option.payload^
		} else if variant, is_variant := scrutinee.(Enum_Value); is_variant {
			if variant.type_name != pattern.type_name || variant.variant != pattern.variant || variant.payload == nil {
				return env, false
			}
			payload = variant.payload^
		} else {
			return env, false
		}
		return match_pattern(pattern.elements[0], payload, env)
	case .Struct_Binds:
		// A struct-payload variant value materializes as a Record_Value carrying
		// its variant tag and fields; the pattern matches on (type_name, variant)
		// and field-puns each named binder from the record's fields. A missing
		// field is a non-match rather than a binding to a hole.
		record, is_record := scrutinee.(Record_Value)
		if !is_record || record.type_name != pattern.type_name || record.variant != pattern.variant {
			return env, false
		}
		child := new_env(env)
		for binder in pattern.binders {
			value, found := record_field_value(record.fields, binder)
			if !found {
				return env, false
			}
			child.bindings[binder] = value
		}
		return child, true
	case .Bare_Binder:
		// A bare binder matches any value and binds it to its single name — a
		// tuple position that captures the whole element (snake's `next` Rng
		// position in `(Option::Some(cell), next)`).
		if len(pattern.binders) != 1 {
			return env, false
		}
		child := new_env(env)
		child.bindings[pattern.binders[0]] = scrutinee
		return child, true
	case .Tuple:
		// Tuple decomposition: the scrutinee must be a Tuple_Value of the same
		// arity, and every positional sub-pattern must match its element. Binders
		// from every position accumulate into one shared child frame, so
		// `(Option::Some(cell), next)` binds both `cell` (from the nested variant
		// arm) and `next` (the bare binder) for the body — the §04 §1 pick-result
		// destructure. A non-tuple, an arity mismatch, or any position miss is a
		// non-match.
		return match_tuple_pattern(pattern, scrutinee, env)
	}
	return env, false
}

// match_tuple_pattern destructures a tuple scrutinee against a tuple pattern:
// each positional sub-pattern is matched against the element at the same
// position by a recursive match_pattern, threading the accumulating binder frame
// through every position so binders from all positions are visible in the arm
// body. The threaded frame starts at `env` and each matched sub-pattern returns
// the next frame (a child when it bound names, the same frame otherwise).
match_tuple_pattern :: proc(pattern: Pattern, scrutinee: Value, env: ^Env) -> (frame: ^Env, matched: bool) {
	tuple, is_tuple := scrutinee.(Tuple_Value)
	if !is_tuple || len(tuple.elements) != len(pattern.elements) {
		return env, false
	}
	current := env
	for sub, i in pattern.elements {
		next, sub_matched := match_pattern(sub, tuple.elements[i], current)
		if !sub_matched {
			return env, false
		}
		current = next
	}
	return current, true
}

// eval_unary lowers the two unary forms (spec §02): numeric negation `-x` over a
// Fixed/Int, and the word operator `not x` over a Bool — the `not contains(occ,
// c)` predicate body snake's free-cell filter takes. `not` is carried as an
// Ident token (parse_unary), so it is keyed by text, not kind.
eval_unary :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Unary_Expr) -> (value: Value, ok: bool) {
	operand := eval_expr(ctx, env, e.operand) or_return
	if e.op.kind == .Ident && e.op.text == "not" {
		b, is_bool := operand.(bool)
		if !is_bool {
			return nil, false
		}
		return !b, true
	}
	if e.op.kind != .Minus {
		return nil, false
	}
	#partial switch v in operand {
	case Fixed:
		return fixed_neg(v), true
	case i64:
		return int_neg(v), true
	}
	return nil, false
}

eval_binary :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Binary_Expr) -> (value: Value, ok: bool) {
	lhs := eval_expr(ctx, env, e.lhs) or_return
	rhs := eval_expr(ctx, env, e.rhs) or_return
	if e.op.kind == .Eq_Eq {
		return value_equal(lhs, rhs), true
	}
	if e.op.kind == .Not_Eq {
		return !value_equal(lhs, rhs), true
	}
	if compared, handled := eval_comparison(e.op.kind, lhs, rhs); handled {
		return compared, true
	}
	if e.op.kind == .Ident {
		return eval_logical(e.op.text, lhs, rhs)
	}
	#partial switch l in lhs {
	case Fixed:
		r, is_fixed := rhs.(Fixed)
		if !is_fixed {
			return nil, false
		}
		#partial switch e.op.kind {
		case .Plus:
			return fixed_add(l, r), true
		case .Minus:
			return fixed_sub(l, r), true
		case .Star:
			return fixed_mul(l, r), true
		case .Slash:
			return fixed_div(l, r), true
		case .Percent:
			return fixed_mod(l, r), true
		}
	case i64:
		r, is_int := rhs.(i64)
		if !is_int {
			return nil, false
		}
		#partial switch e.op.kind {
		case .Plus:
			return int_add(l, r), true
		case .Minus:
			return int_sub(l, r), true
		case .Star:
			return int_mul(l, r), true
		case .Slash:
			return int_div(l, r), true
		case .Percent:
			return int_mod(l, r), true
		}
	case Vec2_Value:
		return eval_vec2_binary(e.op.kind, l, rhs)
	case Vec3_Value:
		return eval_vec3_binary(e.op.kind, l, rhs)
	}
	return nil, false
}

// eval_comparison handles the ordering operators (< <= > >=) over two
// same-typed numeric scalars into a Bool. handled = false for any other
// operator so the caller continues to the arithmetic arms.
eval_comparison :: proc(op: Token_Kind, lhs, rhs: Value) -> (value: Value, handled: bool) {
	#partial switch op {
	case .Lt, .Lt_Eq, .Gt, .Gt_Eq:
	case:
		return nil, false
	}
	if l, is_fixed := lhs.(Fixed); is_fixed {
		if r, ok := rhs.(Fixed); ok {
			return compare_ordered(op, i64(l), i64(r)), true
		}
	}
	if l, is_int := lhs.(i64); is_int {
		if r, ok := rhs.(i64); ok {
			return compare_ordered(op, l, r), true
		}
	}
	return nil, false
}

compare_ordered :: proc(op: Token_Kind, l, r: i64) -> bool {
	#partial switch op {
	case .Lt:
		return l < r
	case .Lt_Eq:
		return l <= r
	case .Gt:
		return l > r
	case .Gt_Eq:
		return l >= r
	}
	return false
}

// eval_logical evaluates the word operators `and`/`or` over two Bool sides.
// Both sides are already evaluated (the kernel has no short-circuit shape),
// matching the typecheck that demands two Bool operands.
eval_logical :: proc(op: string, lhs, rhs: Value) -> (value: Value, ok: bool) {
	l, l_bool := lhs.(bool)
	r, r_bool := rhs.(bool)
	if !l_bool || !r_bool {
		return nil, false
	}
	switch op {
	case "and":
		return l && r, true
	case "or":
		return l || r, true
	}
	return nil, false
}

// eval_vec2_binary lowers Vec2 arithmetic: Vec2 ± Vec2 component-wise, and
// Vec2 * Fixed component scaling — the `at + vel*dt` form the pong advance
// helper takes (spec §10).
eval_vec2_binary :: proc(op: Token_Kind, l: Vec2_Value, rhs: Value) -> (value: Value, ok: bool) {
	if r, is_vec := rhs.(Vec2_Value); is_vec {
		#partial switch op {
		case .Plus:
			return vec2_add(l, r), true
		case .Minus:
			return vec2_sub(l, r), true
		}
		return nil, false
	}
	if s, is_fixed := rhs.(Fixed); is_fixed && op == .Star {
		return vec2_scale(l, s), true
	}
	return nil, false
}

eval_vec3_binary :: proc(op: Token_Kind, l: Vec3_Value, rhs: Value) -> (value: Value, ok: bool) {
	if r, is_vec := rhs.(Vec3_Value); is_vec {
		#partial switch op {
		case .Plus:
			return vec3_add(l, r), true
		case .Minus:
			return vec3_sub(l, r), true
		}
		return nil, false
	}
	if s, is_fixed := rhs.(Fixed); is_fixed && op == .Star {
		return vec3_scale(l, s), true
	}
	return nil, false
}

// eval_member resolves a type's associated constants (Fixed.MAX, Fixed.MIN,
// Quat.identity) and field access off a value receiver — a user record's
// declared field (self.pos) or a Vec2/Vec3 component (v.x).
eval_member :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Member_Expr) -> (value: Value, ok: bool) {
	if recv, is_name := e.receiver.(^Name_Expr); is_name {
		if _, bound := env_lookup(env, recv.name); !bound {
			// A whole-module handle (`assets`) is not a local binding and not a
			// type-name constant — a `handle.member` reaches a sibling module's
			// exported const, evaluated in its owning module's environment.
			if const_value, is_const := eval_module_qualified_const(ctx, recv.name, e.member); is_const {
				return const_value, true
			}
			switch recv.name {
			case "Fixed":
				switch e.member {
				case "MAX":
					return FIXED_MAX, true
				case "MIN":
					return FIXED_MIN, true
				}
			case "Quat":
				if e.member == "identity" {
					return QUAT_IDENTITY, true
				}
			}
		}
	}
	receiver := eval_expr(ctx, env, e.receiver) or_return
	return eval_field_access(receiver, e.member)
}

// eval_module_qualified_const evaluates a cross-module const reference
// `handle.member` (`assets.coin_sfx`): the handle name must bind to a sibling user
// module as a .Module handle, that module's eval surface must be in scope, and the
// member must be a module-level let in it. The let's initializer evaluates against
// a FRESH Eval_Ctx over the OWNING module's (ast, env, bindings) — so the value is
// exactly what that module's own test would compute for the bare const name (the
// §19 seam's SoundHandle{name: "coin_sfx"}), and a const RHS that itself reaches a
// further sibling resolves through the shared module surface. is_const = false when
// the handle is not a module binding or the member is not its let, so the caller
// falls through to its other member arms.
eval_module_qualified_const :: proc(ctx: Eval_Ctx, handle: string, member: string) -> (value: Value, is_const: bool) {
	binding, bound := ctx.bindings.names[handle]
	if !bound || binding.kind != .Module {
		return nil, false
	}
	owner, found := module_eval_lookup(ctx.modules, binding.module)
	if !found {
		return nil, false
	}
	// The owner ctx evaluates the let in its OWNING module — so its module name
	// is the owner's, the namespace half of the const's cycle key — and SHARES
	// the visited set (threaded by pointer) so a cross-module cycle (two
	// mutually-importing modules whose consts reference each other) trips the
	// same guard the intra-module path uses.
	owner_ctx := Eval_Ctx {
		ast      = owner.ast,
		env      = owner.env,
		bindings = owner.bindings,
		modules  = owner.modules,
		module   = binding.module,
		visiting = ctx.visiting,
	}
	return eval_module_const(owner_ctx, member)
}

// module_eval_lookup finds a module's eval surface by name, walked by index like
// every table here — never a map (the determinism tripwire). A name no sibling
// module owns is the caller's miss.
module_eval_lookup :: proc(modules: []Module_Eval, module: string) -> (entry: Module_Eval, found: bool) {
	for candidate in modules {
		if candidate.module == module {
			return candidate, true
		}
	}
	return Module_Eval{}, false
}

// eval_field_access reads a member off a value: a user record's field
// (Goal.side, self.pos), a Vec2/Vec3 component (v.x), or the §04 Time resource's
// dt/t — `dt` is the per-tick delta in fixed seconds the hunt search countdown
// folds, `t` the accumulated logical time since startup the renderer's idle bob
// samples.
eval_field_access :: proc(receiver: Value, member: string) -> (value: Value, ok: bool) {
	#partial switch r in receiver {
	case Record_Value:
		return record_field_value(r.fields, member)
	case Time_Value:
		switch member {
		case "dt":
			return r.dt, true
		case "t":
			return r.t, true
		}
	case Vec2_Value:
		switch member {
		case "x":
			return r.x, true
		case "y":
			return r.y, true
		}
	case Vec3_Value:
		switch member {
		case "x":
			return r.x, true
		case "y":
			return r.y, true
		case "z":
			return r.z, true
		}
	}
	return nil, false
}

eval_call :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if member, is_method := e.callee.(^Member_Expr); is_method {
		return eval_method_call(ctx, env, member, e.args)
	}
	name, is_name := e.callee.(^Name_Expr)
	if !is_name {
		return nil, false
	}
	switch name.name {
	case "to_fixed":
		if len(e.args) != 1 {
			return nil, false
		}
		arg := eval_expr(ctx, env, e.args[0]) or_return
		n, is_int := arg.(i64)
		if !is_int {
			return nil, false
		}
		return to_fixed(n), true
	case "trunc":
		f := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return fixed_trunc(f), true
	case "floor":
		f := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return fixed_floor(f), true
	case "round":
		f := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return fixed_round(f), true
	case "abs":
		f := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return fixed_abs(f), true
	case "clamp":
		x := eval_fixed_arg(ctx, env, e, 0, 3) or_return
		lo := eval_fixed_arg(ctx, env, e, 1, 3) or_return
		hi := eval_fixed_arg(ctx, env, e, 2, 3) or_return
		return fixed_clamp(x, lo, hi), true
	case "lerp":
		a := eval_fixed_arg(ctx, env, e, 0, 3) or_return
		b := eval_fixed_arg(ctx, env, e, 1, 3) or_return
		t := eval_fixed_arg(ctx, env, e, 2, 3) or_return
		return fixed_lerp(a, b, t), true
	case "checked_div":
		a := eval_fixed_arg(ctx, env, e, 0, 2) or_return
		b := eval_fixed_arg(ctx, env, e, 1, 2) or_return
		quotient, has_quotient := fixed_checked_div(a, b)
		if !has_quotient {
			return Option_Value{is_some = false, payload = nil}, true
		}
		boxed := new(Value, context.temp_allocator)
		boxed^ = quotient
		return Option_Value{is_some = true, payload = boxed}, true
	case "dot":
		if len(e.args) != 2 {
			return nil, false
		}
		lhs := eval_expr(ctx, env, e.args[0]) or_return
		rhs := eval_expr(ctx, env, e.args[1]) or_return
		if a2, is_vec2 := lhs.(Vec2_Value); is_vec2 {
			b2 := rhs.(Vec2_Value) or_return
			return vec2_dot(a2, b2), true
		}
		a3 := lhs.(Vec3_Value) or_return
		b3 := rhs.(Vec3_Value) or_return
		return vec3_dot(a3, b3), true
	case "cross":
		if len(e.args) != 2 {
			return nil, false
		}
		lhs := eval_expr(ctx, env, e.args[0]) or_return
		rhs := eval_expr(ctx, env, e.args[1]) or_return
		a3 := lhs.(Vec3_Value) or_return
		b3 := rhs.(Vec3_Value) or_return
		return vec3_cross(a3, b3), true
	case "length":
		if len(e.args) != 1 {
			return nil, false
		}
		arg := eval_expr(ctx, env, e.args[0]) or_return
		if v2, is_vec2 := arg.(Vec2_Value); is_vec2 {
			return vec2_length(v2), true
		}
		v3 := arg.(Vec3_Value) or_return
		return vec3_length(v3), true
	case "sin":
		angle := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return fixed_sin(angle), true
	case "cos":
		angle := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return fixed_cos(angle), true
	case "rot_x":
		// §16 §7 the per-bone X-axis rotation builder: a fixed-point angle
		// (radians) into a Transform with the identity translation, a rotation of
		// `angle` about the local X axis, and unit scale — the leg/arm swing a pose
		// generator drives a bone with (pose_walk's rot_x(s)). At angle 0 the
		// quaternion is the identity, so rot_x(0.0) is the rest transform.
		angle := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return transform_rot_x(angle), true
	case "up":
		// §16 §7 the per-bone vertical-offset builder: a fixed-point displacement
		// into a Transform translating by `d` along the local +Y axis, with the
		// identity rotation and unit scale — pose_idle's torso breathing bob.
		d := eval_fixed_arg(ctx, env, e, 0, 1) or_return
		return transform_up(d), true
	case "max":
		return eval_max(ctx, env, e)
	case "fold":
		return eval_fold(ctx, env, e)
	case "first":
		return eval_first(ctx, env, e)
	case "within":
		return eval_within(ctx, env, e)
	case "nearest_first":
		return eval_nearest_first(ctx, env, e)
	case "prepend":
		return eval_prepend(ctx, env, e)
	case "init":
		return eval_init(ctx, env, e)
	case "contains":
		return eval_contains(ctx, env, e)
	case "concat":
		return eval_concat(ctx, env, e)
	case "is_empty":
		return eval_is_empty(ctx, env, e)
	case "get":
		return eval_get(ctx, env, e)
	case "map":
		return eval_map(ctx, env, e)
	case "filter":
		return eval_filter(ctx, env, e)
	case "grid_cells":
		return eval_grid_cells(ctx, env, e)
	case "mesh":
		return eval_asset_constructor(ctx, env, e, "MeshHandle")
	case "texture":
		return eval_asset_constructor(ctx, env, e, "TextureHandle")
	case "sound":
		return eval_asset_constructor(ctx, env, e, "SoundHandle")
	case "atlas":
		return eval_asset_constructor(ctx, env, e, "AtlasHandle")
	}
	// A call to a user-declared top-level fn (advance, goal_side, add_goal) or
	// a §08 §3 query — call_check admits both kinds at call position, so the
	// evaluator resolves both: the body comes off the module and runs against
	// the arguments through the one eval_user_fn funnel.
	if fn, indexes, declared := find_user_callable(ctx.ast, name.name); declared {
		args := eval_args(ctx, env, e.args) or_return
		body_ctx := ctx
		body_ctx.query_indexes = indexes
		return eval_user_fn(body_ctx, fn, args)
	}
	// A bare name bound by IMPORT to a sibling user module's fn (§15: the
	// declaration's module of origin is invisible at the use site — including
	// a §30 package module's exposed fn called across the package edge). The
	// arguments are CONSUMER expressions, so they evaluate in the consumer
	// ctx/env first; the body then runs in the owner ctx find_imported_fn
	// builds.
	if owner_ctx, fn, found := find_imported_fn(ctx, name.name); found {
		args := eval_args(ctx, env, e.args) or_return
		return eval_user_fn(owner_ctx, fn, args)
	}
	return nil, false
}

// find_imported_fn resolves a bare name an import bound to a sibling user
// module's fn into that fn plus a fresh ctx over the OWNING module's (ast,
// env, bindings) with the caller's shared visited set — mirroring
// eval_module_qualified_const and eval_module_record. Both bare-name fn
// positions resolve through here: the call callee (eval_call) and the
// combinator slot (apply_combinator). An engine.* .Func binding has no user
// eval surface, so module_eval_lookup misses it and found stays false,
// leaving the caller's fall-through arm untouched.
find_imported_fn :: proc(ctx: Eval_Ctx, name: string) -> (owner_ctx: Eval_Ctx, fn: Fn_Node, found: bool) {
	binding, bound := ctx.bindings.names[name]
	if !bound || binding.kind != .Func {
		return
	}
	owner, has_owner := module_eval_lookup(ctx.modules, binding.module)
	if !has_owner {
		return
	}
	user_fn, indexes, declared := find_user_callable(owner.ast, name)
	if !declared {
		return
	}
	owner_ctx = Eval_Ctx {
		ast      = owner.ast,
		env      = owner.env,
		bindings = owner.bindings,
		modules  = owner.modules,
		module   = binding.module,
		visiting = ctx.visiting,
	}
	owner_ctx.query_indexes = indexes
	return owner_ctx, user_fn, true
}

// eval_asset_constructor lowers a §19/§26 manifest-checked string constructor
// (mesh/texture/sound/atlas): a single String asset name into the same typed
// handle value the seam constant's literal builds — Record_Value tagged with the
// handle type, carrying the one `name` field set to the string argument. So
// sound("coin_sfx") evaluates to the identical handle that SoundHandle{name:
// "coin_sfx"} (the typed constant assets.coin_sfx) does, and the two compare equal
// (the §19 golden assertion). The closed-registry kind/name validity is the build
// gate's (asset_registry.odin); the evaluator builds the value the typecheck-passed
// reference names.
eval_asset_constructor :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr, handle_type: string) -> (value: Value, ok: bool) {
	if len(e.args) != 1 {
		return nil, false
	}
	arg := eval_expr(ctx, env, e.args[0]) or_return
	name, is_string := arg.(string)
	if !is_string {
		return nil, false
	}
	fields := make([]Record_Field_Value, 1, context.temp_allocator)
	fields[0] = Record_Field_Value{name = "name", value = name}
	return Record_Value{type_name = handle_type, fields = fields}, true
}

// eval_args evaluates a call's argument expressions left-to-right into a value
// slice — the argument row a user fn or behavior step binds its parameters to.
eval_args :: proc(ctx: Eval_Ctx, env: ^Env, args: []Expr) -> (values: []Value, ok: bool) {
	out := make([]Value, len(args), context.temp_allocator)
	for arg, i in args {
		out[i] = eval_expr(ctx, env, arg) or_return
	}
	return out, true
}

// find_user_fn looks up a top-level user fn by name (advance, goal_side,
// add_goal). A behavior's `step` is reached through eval_method_call, not here.
find_user_fn :: proc(ast: Ast, name: string) -> (fn: Fn_Node, found: bool) {
	for decl in ast.fns {
		if decl.name == name {
			return decl, true
		}
	}
	return Fn_Node{}, false
}

// find_user_callable resolves a name the typecheck side admits as a callable
// term (name_check / call_check, .Fn or .Query): a top-level user fn first,
// then a §08 §3 query projected onto the same Fn_Node window the typing seam
// uses (query_as_fn), so the two sides resolve from one projection and can
// never drift. Both kinds route through eval_user_fn — the single eval
// funnel; a query body runs exactly like a fn body. Serves call position
// (eval_call) and the bare-name combinator slot (apply_combinator); UFCS
// stays on the fn-only find_user_fn, mirroring ufcs_method_check's .Fn-only
// admission, so a query can never shadow a value method the typechecker
// resolved.
//
// A query evaluates UNMEMOIZED here: §08 §3 within-tick memoization keys on
// the immutable MVCC version, and the test interpreter defines no tick and
// no version — a test block evaluates over View.of-style fixture values, so
// there is no key to memoize on, and a query body is pure over its
// arguments, so the result is identical either way. The memo is the
// runtime's concern where the version exists.
find_user_callable :: proc(ast: Ast, name: string) -> (fn: Fn_Node, indexes: []Index_Directive, found: bool) {
	if declared_fn, declared := find_user_fn(ast, name); declared {
		return declared_fn, nil, true
	}
	for decl in ast.queries {
		if decl.name == name {
			// The query's declared requirement set rides along so the caller
			// seeds the body's Eval_Ctx with it — the spatial combinators
			// resolve their measured field from the ENCLOSING query alone.
			return query_as_fn(decl), decl.indexes, true
		}
	}
	return Fn_Node{}, nil, false
}

// eval_within lowers the §08 §3 radius read `within(source, origin, r) ->
// [T]`: every row whose declared @spatial field lies within the fixed-point
// radius of origin — distance through the SAME kernel composition the
// runtime's maintained-structure read pins (spatial_within: vec2_length/
// vec3_length over the component difference, compared `<= r`, no float ever)
// — in SOURCE order (stable Id order for a world read). The measured field
// resolves from the enclosing query's @spatial declaration; a row outside
// the kernel's distance domain (a field/origin arm mismatch) fails closed,
// never a coerced 0 — mirroring the runtime kernel's refusal arm.
eval_within :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 3) or_return
	origin := eval_expr(ctx, env, e.args[1]) or_return
	radius_value := eval_expr(ctx, env, e.args[2]) or_return
	radius, is_fixed := radius_value.(Fixed)
	if !is_fixed {
		return nil, false
	}
	out := make([dynamic]Value, 0, len(elements), context.temp_allocator)
	for element in elements {
		distance := spatial_element_distance(ctx, element, origin) or_return
		if distance <= radius {
			append(&out, element)
		}
	}
	return List_Value{elements = out[:]}, true
}

// eval_nearest_first lowers the §08 §3 nearest-first order
// `nearest_first(source, origin) -> [T]`: ascending kernel distance with the
// STABLE Id tiebreak — a stable sort over a source in stable Id order keeps
// equidistant rows in Id order, exactly the runtime kernel's pinned
// (distance, Id) answer (spatial_hit_less). Distances are measured once per
// row through the same kernel composition eval_within uses.
eval_nearest_first :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 2) or_return
	origin := eval_expr(ctx, env, e.args[1]) or_return
	keyed := make([]Spatial_Keyed_Row, len(elements), context.temp_allocator)
	for element, i in elements {
		distance := spatial_element_distance(ctx, element, origin) or_return
		keyed[i] = Spatial_Keyed_Row{row = element, distance = distance}
	}
	slice.stable_sort_by(keyed, spatial_keyed_row_less)
	out := make([]Value, len(keyed), context.temp_allocator)
	for entry, i in keyed {
		out[i] = entry.row
	}
	return List_Value{elements = out}, true
}

// Spatial_Keyed_Row pairs one source row with its kernel distance — the sort
// key eval_nearest_first orders by.
Spatial_Keyed_Row :: struct {
	row:      Value,
	distance: Fixed,
}

// spatial_keyed_row_less is the nearest-first order's comparator: ascending
// distance ONLY — the stable sort preserves source (Id) order between equal
// distances, which IS the §08 §3 Id tiebreak.
spatial_keyed_row_less :: proc(a, b: Spatial_Keyed_Row) -> bool {
	return a.distance < b.distance
}

// spatial_element_distance measures one row's declared @spatial field against
// the probe origin through the fixed-point kernel — vec2_length/vec3_length
// over the component difference (bit-exact on perfect squares, floor-rounded
// otherwise), the runtime's spatial_distance composition exactly. The field
// resolves from the enclosing query's requirement set; ok is false for a row
// outside the measurable domain (no declaration, a missing field, or an arm
// mismatch between origin and field) — fail closed, mirroring the kernel.
spatial_element_distance :: proc(ctx: Eval_Ctx, element: Value, origin: Value) -> (distance: Fixed, ok: bool) {
	record, is_record := element.(Record_Value)
	if !is_record {
		return 0, false
	}
	field := spatial_field_for(ctx, record.type_name) or_return
	at := record_field_value(record.fields, field) or_return
	#partial switch from in origin {
	case Vec2_Value:
		at2, is_vec2 := at.(Vec2_Value)
		if !is_vec2 {
			return 0, false
		}
		return vec2_length(vec2_sub(at2, from)), true
	case Vec3_Value:
		at3, is_vec3 := at.(Vec3_Value)
		if !is_vec3 {
			return 0, false
		}
		return vec3_length(vec3_sub(at3, from)), true
	}
	return 0, false
}

// spatial_field_for resolves which field the enclosing query's @spatial
// declarations measure for one thing — the eval twin of the typecheck's
// spatial_requirement_field, demanding exactly one match (zero or several
// fail closed; the typing rule already named those verdicts upstream).
spatial_field_for :: proc(ctx: Eval_Ctx, thing: string) -> (field: string, ok: bool) {
	found := false
	for directive in ctx.query_indexes {
		if directive.kind != .Spatial || directive.thing != thing {
			continue
		}
		if found {
			return "", false
		}
		field = directive.field
		found = true
	}
	return field, found
}

// eval_fold reduces strictly left-to-right: acc = combinator(acc, element)
// in element order, never tree-reduced or reordered — fixed-point + is
// not reorder-invariant under saturation, so the order IS the result
// (spec §10). The combinator is a literal lambda or a bare user-fn value
// (tally's fold(goals, self, add_goal) passes the add_goal fn by name).
eval_fold :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 3 {
		return nil, false
	}
	list_value := eval_expr(ctx, env, e.args[0]) or_return
	list := list_value.(List_Value) or_return
	acc := eval_expr(ctx, env, e.args[1]) or_return
	for element in list.elements {
		acc = apply_combinator(ctx, env, e.args[2], {acc, element}) or_return
	}
	return acc, true
}

// eval_first lowers the §08 list combinator first: first(list) yields the
// head wrapped in Option (None on empty), and first(list, pred) yields the
// first element the predicate accepts. The pong serve behavior takes the
// one-argument form over a [Goal] list; the predicate form rides the same
// combinator-application seam fold uses.
eval_first :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 1 && len(e.args) != 2 {
		return nil, false
	}
	source := eval_expr(ctx, env, e.args[0]) or_return
	list := source.(List_Value) or_return
	for element in list.elements {
		if len(e.args) == 1 {
			return some_value(element), true
		}
		verdict := apply_combinator(ctx, env, e.args[1], {element}) or_return
		accepted, is_bool := verdict.(bool)
		if is_bool && accepted {
			return some_value(element), true
		}
	}
	return Option_Value{is_some = false, payload = nil}, true
}

// eval_list_arg evaluates argument i of an expected-arity call and demands a
// list — the shared shape the §08 list combinators read. A View materializes as
// a List_Value (eval reads its rows as elements), so a View argument satisfies
// this just as a literal list does.
eval_list_arg :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr, i: int, arity: int) -> (elements: []Value, ok: bool) {
	if len(e.args) != arity {
		return nil, false
	}
	value := eval_expr(ctx, env, e.args[i]) or_return
	list, is_list := value.(List_Value)
	if !is_list {
		return nil, false
	}
	return list.elements, true
}

// eval_prepend lowers `prepend(elem, list) -> [T]` (spec §08): a fresh list with
// `elem` at the front then every element of `list` in order. Snake's cells()
// prepends the head onto the body. The input list is never mutated.
eval_prepend :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 2 {
		return nil, false
	}
	elem := eval_expr(ctx, env, e.args[0]) or_return
	elements := eval_list_arg(ctx, env, e, 1, 2) or_return
	out := make([]Value, len(elements) + 1, context.temp_allocator)
	out[0] = elem
	for element, i in elements {
		out[i + 1] = element
	}
	return List_Value{elements = out}, true
}

// eval_init lowers `init(list) -> [T]` (spec §08): every element except the last.
// Snake's body_after drops the tail this way when the snake is not growing. The
// empty list yields the empty list (total — no fault on a missing last element).
eval_init :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 1) or_return
	if len(elements) == 0 {
		return List_Value{elements = make([]Value, 0, context.temp_allocator)}, true
	}
	out := make([]Value, len(elements) - 1, context.temp_allocator)
	for i in 0 ..< len(elements) - 1 {
		out[i] = elements[i]
	}
	return List_Value{elements = out}, true
}

// eval_contains lowers `contains(list, elem) -> Bool` (spec §08): true when any
// element structurally equals `elem`. Snake tests `contains(self.body, self.head)`
// over Cell records, so the membership is the deep record equality value_equal folds.
eval_contains :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 2) or_return
	elem := eval_expr(ctx, env, e.args[1]) or_return
	for element in elements {
		if value_equal(element, elem) {
			return true, true
		}
	}
	return false, true
}

// eval_concat lowers `concat(a, b) -> [T]` (spec §08): every element of `a` then
// every element of `b`, both in order. Snake's occupied() concatenates the
// snake's cells with the food cells. Both inputs are read, never mutated.
eval_concat :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	a := eval_list_arg(ctx, env, e, 0, 2) or_return
	b := eval_list_arg(ctx, env, e, 1, 2) or_return
	out := make([]Value, len(a) + len(b), context.temp_allocator)
	for element, i in a {
		out[i] = element
	}
	for element, i in b {
		out[len(a) + i] = element
	}
	return List_Value{elements = out}, true
}

// eval_is_empty lowers `is_empty(list) -> Bool` (spec §08): true when the list
// has no elements. Snake gates grow/replenish/apply_death on an empty signal
// list this way.
eval_is_empty :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 1) or_return
	return len(elements) == 0, true
}

// eval_get lowers `get(list, i) -> Option[T]` (spec §08): the element at index i
// wrapped in Option::Some, or Option::None when i is out of range — total, never
// faulting (the hud preset test reads get(volume_presets, 1)). A negative index is
// out of range and reads None.
eval_get :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 2 {
		return nil, false
	}
	elements := eval_list_arg(ctx, env, e, 0, 2) or_return
	index_value := eval_expr(ctx, env, e.args[1]) or_return
	i, is_int := index_value.(i64)
	if !is_int {
		return nil, false
	}
	if i < 0 || int(i) >= len(elements) {
		return Option_Value{is_some = false, payload = nil}, true
	}
	return some_value(elements[i]), true
}

// eval_max lowers `max(a, b)` (spec §10/§26): the larger of two same-typed
// numeric scalars — Int or Fixed, never crossing the kinds (no implicit
// promotion). Fixed compares by its underlying Q32.32 integer ordering. The hud
// `max(self.clock - 1, 0)` floors the Int countdown at zero.
eval_max :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) != 2 {
		return nil, false
	}
	a := eval_expr(ctx, env, e.args[0]) or_return
	b := eval_expr(ctx, env, e.args[1]) or_return
	if af, a_fixed := a.(Fixed); a_fixed {
		bf, b_fixed := b.(Fixed)
		if !b_fixed {
			return nil, false
		}
		return (i64(af) >= i64(bf)) ? af : bf, true
	}
	if ai, a_int := a.(i64); a_int {
		bi, b_int := b.(i64)
		if !b_int {
			return nil, false
		}
		return (ai >= bi) ? ai : bi, true
	}
	return nil, false
}

// eval_map lowers `map(source, fn) -> [U]` (spec §08): a fresh list applying the
// unary function to each element in source order. The function slot is a literal
// lambda or a bare user-fn name (apply_combinator), the same two forms fold's
// combinator admits. Snake projects food rows to cells and cells to draw rects
// this way; the View source materializes as a list, so map over a View yields a list.
eval_map :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 2) or_return
	out := make([]Value, len(elements), context.temp_allocator)
	for element, i in elements {
		out[i] = apply_combinator(ctx, env, e.args[1], {element}) or_return
	}
	return List_Value{elements = out}, true
}

// eval_filter lowers `filter(source, pred) -> [T]` (spec §08): a fresh list of
// the elements the unary predicate accepts, in source order. Snake's free-cell
// selection filters all_cells() by un-occupied, and detect_eat filters foods by
// the head cell. The kept elements preserve the deterministic source order.
eval_filter :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	elements := eval_list_arg(ctx, env, e, 0, 2) or_return
	kept := make([dynamic]Value, 0, len(elements), context.temp_allocator)
	for element in elements {
		verdict := apply_combinator(ctx, env, e.args[1], {element}) or_return
		accepted, is_bool := verdict.(bool)
		if !is_bool {
			return nil, false
		}
		if accepted {
			append(&kept, element)
		}
	}
	return List_Value{elements = kept[:]}, true
}

// eval_grid_cells lowers both grid_cells arities (spec §18 §4 / §26), selected
// by argument count like the typing arm: the CANONICAL `grid_cells(size: Cell)
// -> [Cell]` enumerates every cell of a size.x×size.y grid as records of the
// argument's own type, and the non-idiomatic mapper `grid_cells(w, h, fn(x, y)
// -> Cell)` builds each cell through the two-arg lambda. Both walk in the SAME
// STABLE ROW-MAJOR order: the outer loop walks rows (y from 0), the inner walks
// columns (x from 0), so the enumeration is machine-identical — driven by the
// loop indices, never by any map iteration. A non-positive extent yields the
// empty list (total). The dimensions are Ints (§10). Snake's all_cells() folds
// free-cell selection through the mapper form.
eval_grid_cells :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr) -> (value: Value, ok: bool) {
	if len(e.args) == 1 {
		size_val := eval_expr(ctx, env, e.args[0]) or_return
		size, is_record := size_val.(Record_Value)
		if !is_record {
			return nil, false
		}
		w_val := record_field_value(size.fields, "x") or_return
		h_val := record_field_value(size.fields, "y") or_return
		w, w_is_int := w_val.(i64)
		h, h_is_int := h_val.(i64)
		if !w_is_int || !h_is_int {
			return nil, false
		}
		count := (w > 0 && h > 0) ? int(w) * int(h) : 0
		out := make([]Value, count, context.temp_allocator)
		idx := 0
		for y in 0 ..< h {
			for x in 0 ..< w {
				// Each cell is a record of the size argument's OWN type — the
				// typing arm pinned its schema to exactly {x: Int, y: Int}, so
				// this construction is total over the declared fields.
				fields := make([]Record_Field_Value, 2, context.temp_allocator)
				fields[0] = Record_Field_Value{name = "x", value = x}
				fields[1] = Record_Field_Value{name = "y", value = y}
				out[idx] = Record_Value{type_name = size.type_name, fields = fields}
				idx += 1
			}
		}
		return List_Value{elements = out}, true
	}
	if len(e.args) != 3 {
		return nil, false
	}
	w_val := eval_expr(ctx, env, e.args[0]) or_return
	h_val := eval_expr(ctx, env, e.args[1]) or_return
	fn_val := eval_expr(ctx, env, e.args[2]) or_return
	w, w_is_int := w_val.(i64)
	h, h_is_int := h_val.(i64)
	lambda, is_lambda := fn_val.(Lambda_Value)
	if !w_is_int || !h_is_int || !is_lambda {
		return nil, false
	}
	count := (w > 0 && h > 0) ? int(w) * int(h) : 0
	out := make([]Value, count, context.temp_allocator)
	idx := 0
	for y in 0 ..< h {
		for x in 0 ..< w {
			cell := apply_lambda(ctx, lambda, {x, y}) or_return
			out[idx] = cell
			idx += 1
		}
	}
	return List_Value{elements = out}, true
}

// some_value boxes a value as Option::Some — the payload pointer a union
// cannot hold inline.
some_value :: proc(inner: Value) -> Value {
	boxed := new(Value, context.temp_allocator)
	boxed^ = inner
	return Option_Value{is_some = true, payload = boxed}
}

// apply_combinator applies a fold/first function argument to an argument row:
// a literal lambda binds its params and evaluates its body, while a bare
// user-fn or query name resolves to the declaration and runs its body — the
// forms a combinator's function slot admits (add_goal by name, a literal
// predicate; name_check reads a bare query name as a function value exactly
// like a fn's, spec §08 §3).
apply_combinator :: proc(ctx: Eval_Ctx, env: ^Env, arg: Expr, args: []Value) -> (value: Value, ok: bool) {
	if lambda, is_lambda := arg.(^Lambda_Expr); is_lambda {
		return apply_lambda(ctx, Lambda_Value{node = lambda, env = env}, args)
	}
	if name, is_name := arg.(^Name_Expr); is_name {
		if fn, indexes, declared := find_user_callable(ctx.ast, name.name); declared {
			body_ctx := ctx
			body_ctx.query_indexes = indexes
			return eval_user_fn(body_ctx, fn, args)
		}
		// An IMPORTED fn in the combinator slot (map(xs, dep_fn)) runs in
		// its owning module's ctx — the same cross-module arm eval_call has;
		// the argument row is already evaluated consumer-side.
		if owner_ctx, fn, found := find_imported_fn(ctx, name.name); found {
			return eval_user_fn(owner_ctx, fn, args)
		}
	}
	return nil, false
}

// eval_method_call dispatches receiver.method(args). The §04 name.step(args)
// behavior-invocation form runs a behavior's step body in test position; a
// Quat type-name receiver selects an associated constructor (Quat.axis_angle);
// a value receiver selects a method on the evaluated quaternion.
eval_method_call :: proc(ctx: Eval_Ctx, env: ^Env, callee: ^Member_Expr, args: []Expr) -> (value: Value, ok: bool) {
	if recv, is_name := callee.receiver.(^Name_Expr); is_name {
		if _, bound := env_lookup(env, recv.name); !bound {
			// A behavior name reached through `.step` runs that behavior's step
			// body against the test arguments (spec §04).
			if behavior, is_behavior := find_user_behavior(ctx.ast, recv.name); is_behavior && callee.member == "step" {
				values := eval_args(ctx, env, args) or_return
				return eval_user_fn(ctx, behavior.step, values)
			}
			if recv.name == "Quat" {
				return eval_quat_constructor(ctx, env, callee.member, args)
			}
			if recv.name == "Pose" {
				return eval_pose_static(ctx, env, callee.member, args)
			}
			// The §22 audio constructors: Sound.sfx(clip)/.sfx_at(clip, pos) and
			// Audio.track(key, clip) build the one-shot / sustained record values the
			// .gain/.pitch/.bus/.at adders then chain. A type name is never an env
			// binding, so this branch only fires for the Type.constructor form.
			if audio, is_audio := eval_audio_constructor(ctx, env, recv.name, callee.member, args); is_audio {
				return audio, true
			}
			// The §23 static resource builders: Input.empty() the empty input
			// snapshot, Time.at(dt) a fixed-dt Time, View.of(list) a §08 read table
			// materialized as a list. A resource name is never an env binding, so
			// this branch only fires for the type-name static-method form.
			if builder, is_builder := eval_resource_builder(ctx, env, recv.name, callee.member, args); is_builder {
				return builder, true
			}
		}
	}
	receiver := eval_expr(ctx, env, callee.receiver) or_return
	// §02 §4 UFCS: recv.f(args) runs the top-level user fn f(recv, args) when f's
	// first param matches the receiver — the hud projections App{}.pause_view() /
	// self.hud_view() are reached this way. Tried before the value-method arms so a
	// user projection fn resolves; a member that names no user fn falls through.
	if ufcs, is_ufcs := eval_ufcs_method(ctx, env, receiver, callee.member, args); is_ufcs {
		return ufcs, true
	}
	// §22 the one-shot / sustained adders on a built Sound/Audio record value
	// (Sound.sfx(clip).bus(Bus::Ui), Audio.track(k, c).gain(g).bus(b)): each
	// returns a new record with one field replaced, so they chain.
	if record, is_record := receiver.(Record_Value); is_record {
		if audio, is_audio := eval_audio_adder(ctx, env, record, callee.member, args); is_audio {
			return audio, true
		}
	}
	// A method call on a value receiver: the §23 §2 Input queries (an inline test
	// seeds the snapshot via Input.empty().with_pressed(…) and reads it via
	// .pressed(…)), then the quaternion methods.
	if input, is_input := receiver.(Input_Value); is_input {
		return eval_input_method(ctx, env, input, callee.member, args)
	}
	// A §18 §4 layer query on a fixture tile layer (the TilemapHandle.of value:
	// map.tile_at(cell), map.solid_at(cell), map.cell_of(pos), map.center_of(cell)).
	if tilemap, is_tilemap := receiver.(Tilemap_Value); is_tilemap {
		return eval_tilemap_method(ctx, env, tilemap, callee.member, args)
	}
	// A §16 §7 method on a Pose value: set(Bone, Transform) drives one bone
	// (returning the Pose, so a generator chains .set across bones), get(Bone)
	// reads a bone's Transform (rest when the pose leaves it undriven).
	if pose, is_pose := receiver.(Pose_Value); is_pose {
		return eval_pose_method(ctx, env, pose, callee.member, args)
	}
	q := receiver.(Quat_Value) or_return
	switch callee.member {
	case "rotate":
		if len(args) != 1 {
			return nil, false
		}
		arg := eval_expr(ctx, env, args[0]) or_return
		v := arg.(Vec3_Value) or_return
		return quat_rotate(q, v), true
	case "mul":
		if len(args) != 1 {
			return nil, false
		}
		arg := eval_expr(ctx, env, args[0]) or_return
		other := arg.(Quat_Value) or_return
		return quat_mul(q, other), true
	case "slerp":
		if len(args) != 2 {
			return nil, false
		}
		other_value := eval_expr(ctx, env, args[0]) or_return
		other := other_value.(Quat_Value) or_return
		t_value := eval_expr(ctx, env, args[1]) or_return
		t := t_value.(Fixed) or_return
		return quat_slerp(q, other, t), true
	}
	return nil, false
}

// eval_ufcs_method lowers a §02 §4 UFCS call recv.method(args) → method(recv,
// args): a top-level user fn whose first parameter is the receiver, called with
// the receiver prepended to the evaluated arguments. is_ufcs is false when the
// member names no user fn (the caller falls through to the value-method arms). The
// hud projections hud_view/pause_view/settings_view (each fn(self: App)) are run
// this way as App{}.pause_view() / self.hud_view().
eval_ufcs_method :: proc(ctx: Eval_Ctx, env: ^Env, receiver: Value, member: string, args: []Expr) -> (value: Value, is_ufcs: bool) {
	fn, declared := find_user_fn(ctx.ast, member)
	if !declared || len(fn.params) == 0 {
		return nil, false
	}
	tail, tail_ok := eval_args(ctx, env, args)
	if !tail_ok {
		return nil, false
	}
	values := make([]Value, len(tail) + 1, context.temp_allocator)
	values[0] = receiver
	copy(values[1:], tail)
	result, ok := eval_user_fn(ctx, fn, values)
	return result, ok
}

// eval_audio_constructor lowers the §22 audio constructors applied as a type-name
// static method: Sound.sfx(clip)/.sfx_at(clip, pos) build the one-shot record at
// the spec defaults (unity gain/pitch, Sfx bus, the given/None position),
// Audio.track(key, clip) the sustained record (Music bus). is_audio is false for
// any other (type, member) so the caller falls through. The records carry exactly
// the §22 fields so a built value compares equal to another built the same way.
eval_audio_constructor :: proc(ctx: Eval_Ctx, env: ^Env, type_name, member: string, args: []Expr) -> (value: Value, is_audio: bool) {
	switch type_name {
	case "Sound":
		switch member {
		case "sfx":
			if len(args) != 1 {
				return nil, false
			}
			clip, clip_ok := eval_expr(ctx, env, args[0])
			if !clip_ok {
				return nil, false
			}
			return sound_record(clip, none_value()), true
		case "sfx_at":
			if len(args) != 2 {
				return nil, false
			}
			clip, clip_ok := eval_expr(ctx, env, args[0])
			pos, pos_ok := eval_expr(ctx, env, args[1])
			if !clip_ok || !pos_ok {
				return nil, false
			}
			return sound_record(clip, some_value(pos)), true
		}
	case "Audio":
		if member == "track" && len(args) == 2 {
			key, key_ok := eval_expr(ctx, env, args[0])
			clip, clip_ok := eval_expr(ctx, env, args[1])
			if !key_ok || !clip_ok {
				return nil, false
			}
			return audio_record(key, clip), true
		}
	}
	return nil, false
}

// sound_record builds a §22 §1 Sound value at unity gain/pitch on the Sfx bus —
// the Sound.sfx/.sfx_at default, before any .gain/.pitch/.bus/.at adder. Field
// order is the §22 record order so equality (which matches by name) is stable.
sound_record :: proc(clip: Value, at: Value) -> Value {
	fields := make([]Record_Field_Value, 5, context.temp_allocator)
	fields[0] = Record_Field_Value{name = "clip", value = clip}
	fields[1] = Record_Field_Value{name = "gain", value = FIXED_ONE}
	fields[2] = Record_Field_Value{name = "pitch", value = FIXED_ONE}
	fields[3] = Record_Field_Value{name = "bus", value = bus_variant("Sfx")}
	fields[4] = Record_Field_Value{name = "at", value = at}
	return Record_Value{type_name = "Sound", fields = fields}
}

// audio_record builds a §22 §2 Audio value at unity gain/pitch on the Music bus —
// the Audio.track default, before any adder.
audio_record :: proc(key: Value, clip: Value) -> Value {
	fields := make([]Record_Field_Value, 6, context.temp_allocator)
	fields[0] = Record_Field_Value{name = "key", value = key}
	fields[1] = Record_Field_Value{name = "clip", value = clip}
	fields[2] = Record_Field_Value{name = "gain", value = FIXED_ONE}
	fields[3] = Record_Field_Value{name = "pitch", value = FIXED_ONE}
	fields[4] = Record_Field_Value{name = "bus", value = bus_variant("Music")}
	fields[5] = Record_Field_Value{name = "at", value = none_value()}
	return Record_Value{type_name = "Audio", fields = fields}
}

// bus_variant is a §22 §4 Bus enum value (Bus::Sfx, Bus::Ui) — the same
// (type_name, variant) Enum_Value a Bus::X literal lowers to, so a default bus
// compares equal to a literal-set one.
bus_variant :: proc(variant: string) -> Value {
	return Enum_Value{type_name = "Bus", variant = variant}
}

// none_value is the Option::None value an unplaced one-shot's `at` field carries.
none_value :: proc() -> Value {
	return Option_Value{is_some = false, payload = nil}
}

// eval_audio_adder lowers a §22 self-first adder on a built Sound/Audio record:
// .gain(g)/.pitch(p) replace the Fixed field, .bus(b) the Bus field, .at(pos) the
// Option position. Each returns a new record with the one field replaced (the base
// untouched), so they chain. is_audio is false when the receiver is not a Sound/
// Audio record or the member is not an adder (the caller falls through).
eval_audio_adder :: proc(ctx: Eval_Ctx, env: ^Env, record: Record_Value, member: string, args: []Expr) -> (value: Value, is_audio: bool) {
	if record.type_name != "Sound" && record.type_name != "Audio" {
		return nil, false
	}
	field: string
	wrap_some := false
	switch member {
	case "gain", "pitch", "bus":
		field = member
	case "at":
		field = "at"
		wrap_some = true
	case:
		return nil, false
	}
	if len(args) != 1 {
		return nil, false
	}
	arg, arg_ok := eval_expr(ctx, env, args[0])
	if !arg_ok {
		return nil, false
	}
	if wrap_some {
		arg = some_value(arg)
	}
	updated := make([]Record_Field_Value, len(record.fields), context.temp_allocator)
	copy(updated, record.fields)
	if !record_replace_field(updated, field, arg) {
		return nil, false
	}
	return Record_Value{type_name = record.type_name, variant = record.variant, fields = updated}, true
}

// eval_resource_builder lowers the static resource builders applied as a
// type-name static method (spec §23 / §18 §4): Input.empty() is the empty input
// snapshot an inline test seeds, Time.at(dt) a fixed-dt Time resource,
// View.of(list) a §08 read table built from a literal list — materialized as a
// List_Value so the list combinators (first/map/filter) read its rows as
// elements exactly as they read a literal list — and TilemapHandle.of(cell_size,
// cells) the §18 §4 fixture tile layer the four layer queries answer over.
// is_builder is false for any other (type, member) pair so the caller falls
// through to its other type-name forms.
eval_resource_builder :: proc(ctx: Eval_Ctx, env: ^Env, type_name, member: string, args: []Expr) -> (value: Value, is_builder: bool) {
	switch type_name {
	case "TilemapHandle":
		if member == "of" && len(args) == 2 {
			return eval_tilemap_fixture(ctx, env, args)
		}
	case "Input":
		if member == "empty" && len(args) == 0 {
			return Input_Value{pressed = make([]Input_Press, 0, context.temp_allocator)}, true
		}
	case "Time":
		if member == "at" && len(args) == 1 {
			dt_value, dt_ok := eval_expr(ctx, env, args[0])
			if !dt_ok {
				return nil, false
			}
			dt, is_fixed := dt_value.(Fixed)
			if !is_fixed {
				return nil, false
			}
			return Time_Value{dt = dt}, true
		}
	case "View":
		if member == "of" && len(args) == 1 {
			source, source_ok := eval_expr(ctx, env, args[0])
			if !source_ok {
				return nil, false
			}
			// View.of(list) materializes the read table as the list itself — a View
			// row read is the underlying element read (the runtime threads View rows
			// to a behavior as a list, so the evaluator mirrors that here).
			list, is_list := source.(List_Value)
			if !is_list {
				return nil, false
			}
			return list, true
		}
	}
	return nil, false
}

// eval_input_method lowers a §23 §2 query on an Input snapshot value: pressed/
// released/held read whether a (player, action) button is in the snapshot's held
// set, with_pressed returns a new snapshot adding one held button, and value/axis
// read the analog channels — which a with_pressed snapshot never seeds, so they
// read the zero / zero-vector default (a behavior never faults on input). The
// (player, action) pair is identified by its variant names (PlayerId::P1,
// Move::Down), matching the snapshot's recorded press identity.
eval_input_method :: proc(ctx: Eval_Ctx, env: ^Env, input: Input_Value, member: string, args: []Expr) -> (value: Value, ok: bool) {
	switch member {
	case "with_pressed":
		player, action, args_ok := eval_input_button_args(ctx, env, args)
		if !args_ok {
			return nil, false
		}
		next := make([]Input_Press, len(input.pressed) + 1, context.temp_allocator)
		copy(next, input.pressed)
		next[len(input.pressed)] = Input_Press{player = player, action = action}
		return Input_Value{pressed = next}, true
	case "pressed", "held":
		player, action, args_ok := eval_input_button_args(ctx, env, args)
		if !args_ok {
			return nil, false
		}
		return input_is_pressed(input, player, action), true
	case "released":
		// A released edge is never set by with_pressed (which marks down-this-tick),
		// so a seeded snapshot reads no release — the §23 §2 default.
		_, _, args_ok := eval_input_button_args(ctx, env, args)
		if !args_ok {
			return nil, false
		}
		return false, true
	case "value":
		// The analog 1D read of an unseeded channel is the zero default.
		_, _, args_ok := eval_input_button_args(ctx, env, args)
		if !args_ok {
			return nil, false
		}
		return Fixed(0), true
	case "axis":
		// The analog 2D read of an unseeded channel is the zero vector default.
		_, _, args_ok := eval_input_button_args(ctx, env, args)
		if !args_ok {
			return nil, false
		}
		return Vec2_Value{}, true
	}
	return nil, false
}

// eval_input_button_args evaluates an Input query's (player, action) argument
// pair to their variant names — the (PlayerId, action-enum) the snapshot keys a
// press on. ok is false on a wrong arity or a non-variant argument.
eval_input_button_args :: proc(ctx: Eval_Ctx, env: ^Env, args: []Expr) -> (player, action: string, ok: bool) {
	if len(args) != 2 {
		return "", "", false
	}
	player_value, p_ok := eval_expr(ctx, env, args[0])
	action_value, a_ok := eval_expr(ctx, env, args[1])
	if !p_ok || !a_ok {
		return "", "", false
	}
	player_variant, is_player := player_value.(Enum_Value)
	action_variant, is_action := action_value.(Enum_Value)
	if !is_player || !is_action {
		return "", "", false
	}
	return player_variant.variant, action_variant.variant, true
}

// input_is_pressed reports whether a (player, action) button is in a snapshot's
// held set — a linear scan over the recorded presses, keyed by variant name.
input_is_pressed :: proc(input: Input_Value, player, action: string) -> bool {
	for press in input.pressed {
		if press.player == player && press.action == action {
			return true
		}
	}
	return false
}

// eval_tilemap_fixture lowers TilemapHandle.of(cell_size, cells) — the §18 §4
// fixture tile layer an inline test seeds where a baked layer would be (the
// View.of/Nav.of mold). cell_size is a positive Int; cells is a list of
// (cell, tile, solid) tuples whose cell is a user Cell record over Int x/y.
// The layer is its own coordinate space anchored at the origin (grid-local),
// so the queries are pure fixed-point grid math — the bake's world bounds and
// y-up flip belong to the runtime's baked handle, never to this fixture. ok is
// false on a malformed seed (a non-positive cell size, a non-tuple row, a
// wrong-shaped cell) — fail-closed; the typecheck-rejected forms never reach a
// passing program.
eval_tilemap_fixture :: proc(ctx: Eval_Ctx, env: ^Env, args: []Expr) -> (value: Value, ok: bool) {
	size_value := eval_expr(ctx, env, args[0]) or_return
	cell_size, size_is_int := size_value.(i64)
	if !size_is_int || cell_size <= 0 {
		return nil, false
	}
	rows_value := eval_expr(ctx, env, args[1]) or_return
	rows, is_list := rows_value.(List_Value)
	if !is_list {
		return nil, false
	}
	cells := make([]Tilemap_Seed_Cell, len(rows.elements), context.temp_allocator)
	cell_type_name := ""
	for element, i in rows.elements {
		row, is_tuple := element.(Tuple_Value)
		if !is_tuple || len(row.elements) != 3 {
			return nil, false
		}
		x, y, type_name, cell_ok := tilemap_cell_coords(row.elements[0])
		tile, tile_is_string := row.elements[1].(string)
		solid, solid_is_bool := row.elements[2].(bool)
		if !cell_ok || !tile_is_string || !solid_is_bool {
			return nil, false
		}
		// The first seeded row's cell type names the layer's Cell record, so
		// cell_of constructs cells of the user's own type (the grid_cells
		// discipline — every row carries the same type once typecheck passes).
		if cell_type_name == "" {
			cell_type_name = type_name
		}
		cells[i] = Tilemap_Seed_Cell{x = x, y = y, tile = tile, solid = solid}
	}
	return Tilemap_Value{cell_size = cell_size, cell_type_name = cell_type_name, cells = cells}, true
}

// eval_tilemap_method lowers a §18 §4 layer query on a fixture tile layer:
// tile_at reads the seeded tile name as Option::Some(name) — an unseeded cell
// is Option::None, total, never a fault; solid_at reads the seeded solid
// verdict — an unseeded cell is not solid (the void is not a wall); cell_of
// floor-divides a world position by the cell size into the containing cell,
// constructed as the seeded cells' own record type; center_of reads a cell's
// world-space center (origin + half cell). All grid-local: the fixture layer
// is anchored at the origin, so every answer is exact fixed-point arithmetic.
eval_tilemap_method :: proc(ctx: Eval_Ctx, env: ^Env, tilemap: Tilemap_Value, member: string, args: []Expr) -> (value: Value, ok: bool) {
	if len(args) != 1 {
		return nil, false
	}
	arg := eval_expr(ctx, env, args[0]) or_return
	switch member {
	case "tile_at":
		x, y, _, cell_ok := tilemap_cell_coords(arg)
		if !cell_ok {
			return nil, false
		}
		seed, found := tilemap_seed_lookup(tilemap.cells, x, y)
		if !found {
			return Option_Value{is_some = false}, true
		}
		return some_value(seed.tile), true
	case "solid_at":
		x, y, _, cell_ok := tilemap_cell_coords(arg)
		if !cell_ok {
			return nil, false
		}
		seed, found := tilemap_seed_lookup(tilemap.cells, x, y)
		if !found {
			return false, true
		}
		return seed.solid, true
	case "cell_of":
		pos, is_vec := arg.(Vec2_Value)
		if !is_vec {
			return nil, false
		}
		fields := make([]Record_Field_Value, 2, context.temp_allocator)
		fields[0] = Record_Field_Value{name = "x", value = tilemap_cell_index(pos.x, tilemap.cell_size)}
		fields[1] = Record_Field_Value{name = "y", value = tilemap_cell_index(pos.y, tilemap.cell_size)}
		return Record_Value{type_name = tilemap.cell_type_name, fields = fields}, true
	case "center_of":
		x, y, _, cell_ok := tilemap_cell_coords(arg)
		if !cell_ok {
			return nil, false
		}
		return Vec2_Value{
			x = tilemap_cell_center(x, tilemap.cell_size),
			y = tilemap_cell_center(y, tilemap.cell_size),
		}, true
	}
	return nil, false
}

// tilemap_cell_coords reads a cell-record value's Int x/y grid coordinates and
// its record type name (the user's own Cell type, which cell_of echoes back —
// the grid_cells discipline). ok is false for a non-record value, missing
// fields, or non-Int coordinates.
tilemap_cell_coords :: proc(cell: Value) -> (x, y: i64, type_name: string, ok: bool) {
	record, is_record := cell.(Record_Value)
	if !is_record {
		return 0, 0, "", false
	}
	x_value, has_x := record_field_value(record.fields, "x")
	y_value, has_y := record_field_value(record.fields, "y")
	if !has_x || !has_y {
		return 0, 0, "", false
	}
	xi, x_is_int := x_value.(i64)
	yi, y_is_int := y_value.(i64)
	if !x_is_int || !y_is_int {
		return 0, 0, "", false
	}
	return xi, yi, record.type_name, true
}

// tilemap_seed_lookup finds a seeded row by cell coordinates — a linear scan
// in seed order (the determinism tripwire: never a map).
tilemap_seed_lookup :: proc(cells: []Tilemap_Seed_Cell, x, y: i64) -> (cell: Tilemap_Seed_Cell, found: bool) {
	for candidate in cells {
		if candidate.x == x && candidate.y == y {
			return candidate, true
		}
	}
	return Tilemap_Seed_Cell{}, false
}

// tilemap_cell_index floor-divides one Q32.32 world coordinate by the Int cell
// size: the grid index of the cell containing the coordinate. Exact over the
// raw bits with floor semantics — a negative position lands in the correct
// negative cell, never truncation's off-by-one toward zero. The fixture
// builder guarantees cell_size > 0, so the i128 quotient adjustment only needs
// the negative-dividend arm.
tilemap_cell_index :: proc(coord: Fixed, cell_size: i64) -> i64 {
	span := i128(cell_size) << FIXED_FRACTION_BITS
	quotient := i128(coord) / span
	if i128(coord) % span != 0 && i128(coord) < 0 {
		quotient -= 1
	}
	return int_saturate(quotient)
}

// tilemap_cell_center is one axis of the §18 §4 center_of: the cell's origin
// (index × cell size, saturating in integer units) plus the half cell, lifted
// to Q32.32 — exact integer arithmetic (an odd cell size's half is a dyadic
// .5, exactly representable), saturating at the rails like every kernel op.
tilemap_cell_center :: proc(index: i64, cell_size: i64) -> Fixed {
	origin := i128(int_mul(index, cell_size)) << FIXED_FRACTION_BITS
	half := i128(cell_size) << (FIXED_FRACTION_BITS - 1)
	return fixed_saturate(origin + half)
}

// eval_quat_constructor lowers the Quat.axis_angle associated constructor.
eval_quat_constructor :: proc(ctx: Eval_Ctx, env: ^Env, member: string, args: []Expr) -> (value: Value, ok: bool) {
	if member != "axis_angle" || len(args) != 2 {
		return nil, false
	}
	axis_value := eval_expr(ctx, env, args[0]) or_return
	axis := axis_value.(Vec3_Value) or_return
	angle_value := eval_expr(ctx, env, args[1]) or_return
	angle := angle_value.(Fixed) or_return
	return quat_axis_angle(axis, angle), true
}

// transform_identity is the §16 §7 rest transform: no translation, the identity
// rotation, unit scale — the transform a Pose assigns to a bone it does not drive
// (Pose.get of an undriven bone), and the base every rot_x/up builds off.
transform_identity :: proc() -> Transform_Value {
	return Transform_Value{
		pos   = Vec3_Value{},
		rot   = QUAT_IDENTITY,
		scale = Vec3_Value{x = FIXED_ONE, y = FIXED_ONE, z = FIXED_ONE},
	}
}

// transform_rot_x builds the §16 §7 rot_x(angle) Transform: the identity
// translation, a quaternion rotating `angle` radians about the local X axis, and
// unit scale. At angle 0 the quaternion is the identity (sin(0)=0, cos(0)=1), so
// rot_x(0.0) equals the rest transform — the zero-crossing the pose_walk golden
// asserts.
transform_rot_x :: proc(angle: Fixed) -> Transform_Value {
	t := transform_identity()
	t.rot = quat_axis_angle(Vec3_Value{x = FIXED_ONE}, angle)
	return t
}

// transform_up builds the §16 §7 up(d) Transform: a translation of `d` along the
// local +Y axis, the identity rotation, and unit scale — the torso bob a pose
// generator drives the torso with.
transform_up :: proc(d: Fixed) -> Transform_Value {
	t := transform_identity()
	t.pos = Vec3_Value{y = d}
	return t
}

// eval_pose_static lowers the §16 §7 Pose Type-name static builders/combinators:
// empty() seeds the sparse pose a generator .set()s bones on; blend(a, b, weight)
// per-bone interpolates two poses; layer(base, overlay) lets the overlay win per
// bone. ok = false for any other (member, arity) shape — a typecheck-rejected
// form that never reaches a passing program.
eval_pose_static :: proc(ctx: Eval_Ctx, env: ^Env, member: string, args: []Expr) -> (value: Value, ok: bool) {
	switch member {
	case "empty":
		if len(args) != 0 {
			return nil, false
		}
		return Pose_Value{bones = make([]Pose_Bone_Transform, 0, context.temp_allocator)}, true
	case "blend":
		if len(args) != 3 {
			return nil, false
		}
		a := eval_pose_expr(ctx, env, args[0]) or_return
		b := eval_pose_expr(ctx, env, args[1]) or_return
		weight := eval_expr(ctx, env, args[2]) or_return
		w, is_fixed := weight.(Fixed)
		if !is_fixed {
			return nil, false
		}
		return eval_pose_blend(a, b, w), true
	case "layer":
		if len(args) != 2 {
			return nil, false
		}
		base := eval_pose_expr(ctx, env, args[0]) or_return
		overlay := eval_pose_expr(ctx, env, args[1]) or_return
		return eval_pose_layer(base, overlay), true
	}
	return nil, false
}

// eval_pose_method lowers the §16 §7 Pose value methods: set(Bone, Transform)
// returns a new pose driving the named bone, get(Bone) reads a bone's transform
// (the rest transform when the pose leaves the bone undriven).
eval_pose_method :: proc(ctx: Eval_Ctx, env: ^Env, pose: Pose_Value, member: string, args: []Expr) -> (value: Value, ok: bool) {
	switch member {
	case "set":
		if len(args) != 2 {
			return nil, false
		}
		bone := eval_bone_arg(ctx, env, args[0]) or_return
		transform_value := eval_expr(ctx, env, args[1]) or_return
		transform, is_transform := transform_value.(Transform_Value)
		if !is_transform {
			return nil, false
		}
		return eval_pose_set(pose, bone, transform), true
	case "get":
		if len(args) != 1 {
			return nil, false
		}
		bone := eval_bone_arg(ctx, env, args[0]) or_return
		return eval_pose_get(pose, bone), true
	}
	return nil, false
}

// eval_pose_set returns a new pose driving `bone` with `transform`: an existing
// driven bone is overwritten in place (a re-`.set` of the same bone replaces, not
// duplicates), a new bone is appended — keeping the driven-bone slice in a
// deterministic insert order, never a map (the determinism tripwire). The input
// pose is never mutated (a fresh slice copy).
eval_pose_set :: proc(pose: Pose_Value, bone: string, transform: Transform_Value) -> Value {
	for driven, i in pose.bones {
		if driven.bone == bone {
			next := make([]Pose_Bone_Transform, len(pose.bones), context.temp_allocator)
			copy(next, pose.bones)
			next[i].transform = transform
			return Pose_Value{bones = next}
		}
	}
	next := make([]Pose_Bone_Transform, len(pose.bones) + 1, context.temp_allocator)
	copy(next, pose.bones)
	next[len(pose.bones)] = Pose_Bone_Transform{bone = bone, transform = transform}
	return Pose_Value{bones = next}
}

// eval_pose_get reads the transform a pose drives on `bone`, or the rest
// (identity) transform when the pose leaves the bone undriven — the §16 §7
// "absent bones default to rest" rule a sparse-pose comparison rests on
// (Pose.get of an undriven bone == identity).
eval_pose_get :: proc(pose: Pose_Value, bone: string) -> Value {
	if transform, found := pose_bone_transform(pose.bones, bone); found {
		return transform
	}
	return transform_identity()
}

// eval_pose_blend per-bone interpolates two poses by `weight` (§16 §7): for every
// bone EITHER pose drives, the result drives the lerp from a's transform (a's
// driven value, or rest when a omits it) to b's (b's driven value, or rest when b
// omits it) — so a blend of disjoint bone sets keeps every bone, each
// interpolating against the other pose's rest. The driven-bone union is built in
// a deterministic order: a's bones in their order, then b's bones new to the
// result in theirs. At weight 0 every bone reads a's transform, at weight 1 b's.
eval_pose_blend :: proc(a, b: Pose_Value, weight: Fixed) -> Value {
	bones := make([dynamic]Pose_Bone_Transform, 0, len(a.bones) + len(b.bones), context.temp_allocator)
	for driven in a.bones {
		// b's side falls back to rest (identity) when b omits the bone — the §16 §7
		// absent-bone rule, matching the b-only loop below (which rests a's side) and
		// eval_pose_get. Without this, a bone a drives but b omits would blend toward
		// the zero-value transform (a degenerate {0,0,0,0} quat), not rest.
		other, found := pose_bone_transform(b.bones, driven.bone)
		if !found {
			other = transform_identity()
		}
		append(&bones, Pose_Bone_Transform{
			bone      = driven.bone,
			transform = transform_blend(driven.transform, other, weight),
		})
	}
	for driven in b.bones {
		if _, already := pose_bone_transform(a.bones, driven.bone); already {
			continue
		}
		append(&bones, Pose_Bone_Transform{
			bone      = driven.bone,
			transform = transform_blend(transform_identity(), driven.transform, weight),
		})
	}
	return Pose_Value{bones = bones[:]}
}

// transform_blend interpolates two transforms: position and scale lerp
// component-wise, orientation slerps — the §16 §7 "lerp position, slerp rotation"
// rule. quat_slerp returns its endpoints bit-exactly, so a weight of 0 yields a
// and 1 yields b without recomputation.
transform_blend :: proc(a, b: Transform_Value, weight: Fixed) -> Transform_Value {
	return Transform_Value{
		pos   = vec3_lerp(a.pos, b.pos, weight),
		rot   = quat_slerp(a.rot, b.rot, weight),
		scale = vec3_lerp(a.scale, b.scale, weight),
	}
}

// vec3_lerp interpolates two vectors component-wise over the saturating kernel —
// each lane through fixed_lerp (spec §10: vector arithmetic is component-wise).
vec3_lerp :: proc(a, b: Vec3_Value, t: Fixed) -> Vec3_Value {
	return Vec3_Value{
		x = fixed_lerp(a.x, b.x, t),
		y = fixed_lerp(a.y, b.y, t),
		z = fixed_lerp(a.z, b.z, t),
	}
}

// eval_pose_layer composes two poses by override (§16 §7): the overlay's bones
// replace the base's, the base shows through elsewhere — overlay wins per bone.
// The result is the base's driven bones (each overwritten by the overlay where it
// drives the same bone) followed by the overlay's bones new to the base, in a
// deterministic order.
eval_pose_layer :: proc(base, overlay: Pose_Value) -> Value {
	bones := make([dynamic]Pose_Bone_Transform, 0, len(base.bones) + len(overlay.bones), context.temp_allocator)
	for driven in base.bones {
		if over, wins := pose_bone_transform(overlay.bones, driven.bone); wins {
			append(&bones, Pose_Bone_Transform{bone = driven.bone, transform = over})
		} else {
			append(&bones, driven)
		}
	}
	for driven in overlay.bones {
		if _, already := pose_bone_transform(base.bones, driven.bone); already {
			continue
		}
		append(&bones, driven)
	}
	return Pose_Value{bones = bones[:]}
}

// eval_pose_expr evaluates an expression expected to be a Pose value — the
// shared shape blend/layer read their pose arguments through. ok = false on a
// non-Pose value (a typecheck-rejected shape that never reaches a passing test).
eval_pose_expr :: proc(ctx: Eval_Ctx, env: ^Env, expr: Expr) -> (pose: Pose_Value, ok: bool) {
	value := eval_expr(ctx, env, expr) or_return
	return value.(Pose_Value)
}

// eval_bone_arg evaluates an argument expected to be a Bone variant and returns
// its variant name — the key a Pose drives a transform on. ok = false on a
// non-variant argument.
eval_bone_arg :: proc(ctx: Eval_Ctx, env: ^Env, expr: Expr) -> (bone: string, ok: bool) {
	value := eval_expr(ctx, env, expr) or_return
	variant, is_variant := value.(Enum_Value)
	if !is_variant {
		return "", false
	}
	return variant.variant, true
}

// find_user_behavior looks up a behavior by name — the §04 name.step receiver.
find_user_behavior :: proc(ast: Ast, name: string) -> (behavior: Behavior_Node, found: bool) {
	for decl in ast.behaviors {
		if decl.name == name {
			return decl, true
		}
	}
	return Behavior_Node{}, false
}

// eval_fixed_arg evaluates argument i of an expected-arity call and
// demands a Fixed — the shared shape of the scalar-surface builtins.
eval_fixed_arg :: proc(ctx: Eval_Ctx, env: ^Env, e: ^Call_Expr, i: int, arity: int) -> (f: Fixed, ok: bool) {
	if len(e.args) != arity {
		return Fixed(0), false
	}
	value := eval_expr(ctx, env, e.args[i]) or_return
	return value.(Fixed)
}
