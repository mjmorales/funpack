// Typecheck for the §06/§07 gameplay surface and the evaluable numeric
// domain alike: every free name binds to exactly one declaration — a
// let/param binding, a user thing/data/enum/signal/fn/behavior, or an
// imported surface member (spec §02: one name, one meaning) — and an
// unresolved name is a compile error, never a fallback. There is no
// implicit promotion (spec §10): equality and arithmetic demand same-typed
// sides, and the Int → Fixed lift is the explicit to_fixed call.
//
// The pass runs in two sweeps over the resolved environment (resolve.odin):
// the body sweep types every top-level fn body and behavior step body
// against its parameters — a behavior's params are its reads, its return is
// its writes (spec §06 §3) — and the test sweep types each test block,
// including the §04 `name.step(args)` behavior-invocation form. Both sweeps
// share expr_check. Types are the parameterized model in type.odin; the
// engine/stdlib types the value kernel does not ground (View[T], Spawn,
// Draw, Input, Time, Bindings, the engine enums) carry nominal Engine_Type
// handles, with the axis-role and axis-source boundaries staying the nil
// unknown the typing pass cannot ground further.
package funpack

Type_Error :: enum {
	None,
	Assert_Not_Bool,  // an assert whose expression is not Bool-typed
	Type_Mismatch,    // differently-typed sides — no implicit promotion
	Unsupported_Expr, // a parsed form outside the typeable domain
	Unknown_Module,   // an import naming a module outside the surface
	Unknown_Member,   // an import naming a member its module lacks
	Package_Private,  // a package-edge import (or module-handle access) naming a declaration its package does not @expose — across the §30 §6 boundary an item is importable iff @expose'd; within a project this never fires (public-by-default, spec §15 §4)
	Package_Imports_Package, // a §30 §2 star-graph violation: a PACKAGE module's import names a module beyond engine + its own package — another package's namespace, or a module of the consuming game. A package depends only on engine; the dependency graph is a star with the game as its hub, so the refusal is named, never folded into .Unknown_Module (the module exists — the package just may not reach it)
	Expose_Closure_Violation, // an @expose'd declaration whose public signature references a non-@expose'd user type (spec §30 §6, §27 §2: an exposed declaration may reference only exposed, primitive, or stdlib types) — the named-both-ends diagnostic rides expose_closure_verdict (expose_closure.odin)
	Unresolved_Name,  // a free name with no let binding, no user decl, and no import
	Name_Collision,   // one name, two meanings (spec §02): a user decl colliding with an import or another user decl, or two imports binding one name to different declarations
	Unregistered_Layer, // a Body's layer/mask names a value outside any CollisionLayer-kinded enum's variant set (spec §11 §5)
	Reserved_Signal_Name, // a user signal declared under an engine-routed name (Trigger/Contact, spec §11 §4) — the runtime routes those names per-instance, so the user signal would silently never broadcast
	Tuple_Pattern_Arity,  // a tuple match pattern whose positional arity disagrees with its Tuple-typed scrutinee (spec §02 §5) — a 2-binder pattern over a 3-tuple can never bind coherently
	Migrate_From_Collision, // a @migrate rename whose prior name is still live (spec §05 §6 + the epic's admissibility rule): a `from:` naming a current field of the same data, or — decl-level — a current type declaration; the "old" name being live contradicts the rename
	Migrate_Convert_Unknown, // a @migrate `with:` naming no fn this module declares — the conversion must resolve to a declared pure fn (spec §05 §6)
	Migrate_Convert_Arity,   // a @migrate conversion that is not a single-parameter fn — the spec's shape is `fn(Old) -> New`, exactly one value in (spec §05 §6)
	Migrate_Convert_Return,  // a @migrate conversion whose declared return type differs from the migrated field's declared (new) type — `fn(Old) -> New` must land on New (spec §05 §6)
	Index_Unknown_Thing,     // an @index/@spatial FieldPath whose head names no declared thing/singleton — the §05 §3 index is instance-level, so only a thing (a table of rows) can carry one
	Index_Unknown_Field,     // an @index/@spatial FieldPath naming a declared thing but a field that thing's schema lacks (spec §05 §3, §08 §3)
	All_Outside_Query,       // the §08 §3 world read `all[T]` used outside a query body — a query is the read path's only world-reading declaration; a behavior reads through its declared View/signal params, never `all[T]`
	All_Unknown_Thing,       // an `all[T]` whose T names no declared thing/singleton — the read table is a thing's instance set, so a data/enum/signal (or undeclared) head has no rows to read
	Spatial_Requirement_Missing,   // a within/nearest_first whose element thing has no @spatial declared on the ENCLOSING query (spec §08 §3: a query needing an index must declare it) — including any use outside a query body, where no requirement can be declared at all
	Spatial_Requirement_Ambiguous, // a within/nearest_first whose element thing carries SEVERAL @spatial declarations on the enclosing query — the combinator cannot pick which field to measure, so the declaration set must name exactly one
	Query_Param_Not_Value,         // a query parameter outside the value domain — a View[T], a Ref/Owned handle, a resource (Input/Time/Rng/Bindings/Nav), or a function — spec §08 §3: a query is pure over (version, params), takes ONLY value parameters, and reads the world through `all[T]` alone
}

// Scope maps a body's or test block's bound names to their checked types —
// fn/step parameters, let bindings, lambda parameters, and match-arm payload
// binders. Lookups only — nothing iterates the map.
Scope :: map[string]Type

// Check_Ctx threads the file-level import resolutions, the resolved
// user-declaration environment (resolve.odin), the project-wide module index
// (for a cross-module body type/call), and the current scope through expression
// checking. expected_return is the body sweep's declared `-> R` type, against
// which a `return`/`if`-arm `return` is checked; it is nil in the test sweep,
// where statements are let/assert with no return. index is empty (single-source)
// for stage_typecheck and the project-wide index for stage_typecheck_indexed —
// the seam a cross-module call (`arena_spawns()`) resolves its signature through.
// Every map is lookup-only below stage_typecheck.
Check_Ctx :: struct {
	bindings:        Bindings,
	env:             Type_Env,
	index:           Module_Index,
	scope:           Scope,
	expected_return: Type,
	// in_query marks the body sweep over a §08 §3 query declaration — the one
	// context the world read `all[T]` (and the spatial combinators over it)
	// is admitted in; query_indexes carries that query's declared @index/
	// @spatial requirements so the spatial combinators resolve their measured
	// field. Both stay zero for fn/behavior/test sweeps.
	in_query:        bool,
	query_indexes:   []Index_Directive,
	// importer_root is the checked module's own §30 package root ("" = a
	// consuming-project module), threaded so the whole-module-handle member
	// route (module_member_check) gates the package edge from the SAME vantage
	// the import resolver used — a package module reading its own sibling
	// never crosses the edge (spec §15 §5).
	importer_root:   string,
}

stage_typecheck :: proc(ast: Ast) -> (typed: Typed_Ast, err: Type_Error) {
	return stage_typecheck_indexed(ast, Module_Index{})
}

// stage_typecheck_indexed types a module against a project-wide Module_Index so a
// cross-module import (a sibling user module's type or fn) resolves: imports bind
// through resolve_imports_indexed, the env resolves cross-module type refs, and a
// cross-module CALL resolves its signature off the index (call_check). An empty
// index reduces this to the single-source stage_typecheck — every user-module
// import is .Unknown_Module. It is the multi-module project pipeline's per-module
// typecheck (the arena example: arena_game types against arena_world + the arena
// seam), keeping the single-source entry unchanged for every non-importing module.
// importer_root is the module's own §30 package root ("" = a consuming-project
// module): a §30 path-dependency's source types from its own vantage, so its
// package-internal imports resolve and any reach beyond engine + its own
// package is the named star-graph refusal (resolve_package_entry).
stage_typecheck_indexed :: proc(ast: Ast, index: Module_Index, importer_root := "") -> (typed: Typed_Ast, err: Type_Error) {
	bindings := resolve_imports_indexed(ast, index, importer_root) or_return
	env := resolve_env(ast, bindings, index) or_return
	// The §11 §5 layer registry is a pure-AST membership rule (it reads the
	// CollisionLayer enums' variant sets, not resolved value types), so it runs
	// BEFORE body/test typing — an unregistered layer surfaces as the precise
	// Unregistered_Layer diagnostic rather than the generic Type_Mismatch the
	// later variant check would raise for the same out-of-set reference.
	check_layer_registry(ast) or_return
	// The §05 §6 @migrate admissibility rules are likewise pure-AST membership
	// rules (live-name collision, declared-fn shape), so they run before body
	// typing and surface their precise verdicts.
	check_migrations(ast) or_return
	// The §05 §3 @index/@spatial FieldPath rules are pure-AST membership rules
	// too (the path must name a declared thing and one of its fields), so they
	// run before body typing and surface their precise verdicts.
	check_index_paths(ast) or_return
	// The §30 §6 / §27 §2 exposure closure is a signature-level membership rule
	// over the resolved name surface (this module's own type declarations plus
	// the import bindings against the project index), so it runs before body
	// typing too and surfaces its precise verdict (expose_closure.odin).
	check_expose_closure(ast, bindings, index) or_return
	check_bodies(bindings, env, index, ast, importer_root) or_return
	check_tests(bindings, env, index, ast, importer_root) or_return
	return Typed_Ast{ast = ast, bindings = bindings, env = env}, .None
}

// check_layer_registry enforces the §11 §5 collision-layer registry: a Body's
// `layer` and `mask` fields reference an enum variant, and every such variant
// must belong to the registered closed set — the union of every
// CollisionLayer-kinded enum's variants (`enum Layer: CollisionLayer { … }`). A
// layer outside that set is a compile error, checked like a @gtag. The registry
// is built from the ordered ast.enums slice (never the env's enum MAP — that is
// the determinism tripwire), so the verdict is reproducible from the source
// alone. It runs BEFORE body/test typing (see stage_typecheck) so an
// unregistered layer surfaces as the precise Unregistered_Layer diagnostic
// rather than the generic Type_Mismatch the later variant check would raise; it
// adds only the registry rule the field schema cannot express (layer/mask type
// as the nil unknown, since the enum is the user's, not the closed surface's).
check_layer_registry :: proc(ast: Ast) -> Type_Error {
	registry := collision_layer_registry(ast)
	// A holed decl's body is empty, but its @stub(T, fallback) approximation is
	// an expression position like any other — a Body literal inside a fallback
	// is gated here, not exempted by the hole (spec §05 §2 holes are
	// dev-first-class, §11 §5 has no dev tier).
	for fn in ast.fns {
		layer_walk_body(fn.body, registry) or_return
		if fn.has_fallback {
			layer_walk_expr(fn.fallback, registry) or_return
		}
	}
	for behavior in ast.behaviors {
		layer_walk_body(behavior.step.body, registry) or_return
		if behavior.step.has_fallback {
			layer_walk_expr(behavior.step.fallback, registry) or_return
		}
	}
	for test in ast.tests {
		layer_walk_body(test.body, registry) or_return
	}
	return .None
}

// collision_layer_registry collects the registered layer names — the variants
// of every CollisionLayer-kinded enum the source declares (spec §11 §5: a
// project-declared closed set). Built from the ordered ast.enums slice so the
// set is determinism-stable. A source with no CollisionLayer enum has an empty
// registry, so any Body layer/mask reference is unregistered.
collision_layer_registry :: proc(ast: Ast) -> []string {
	names := make([dynamic]string, 0, 8, context.temp_allocator)
	for decl in ast.enums {
		if decl.kind != "CollisionLayer" {
			continue
		}
		for variant in decl.variants {
			append(&names, variant.name)
		}
	}
	return names[:]
}

// check_migrations enforces the §05 §6 @migrate admissibility rules over every
// data declaration — pure AST, like the layer registry, since both halves are
// membership rules the body sweep cannot see. A RENAME's prior name must not
// collide with a live name (a field-level `from:` against the same data's
// current field set; a decl-level `from:` against the module's declared type
// names — the symmetric application of the field rule): a "prior" name that is
// still live contradicts the rename and would make the name-keyed diff
// (spec §09 §4) ambiguous. A RETYPE's conversion must be admissible per the
// spec's `fn(Old) -> New` shape: `with:` resolves to a fn this module
// declares, taking exactly one parameter and returning the migrated field's
// declared (new) type. Old — the parameter's type — is deliberately NOT
// checked: the prior schema is not in this compilation, so the parameter type
// IS the migration's claim about it, verified by the loader's schema-diff at
// migration time. Walks the ordered ast slices only, never an env map, so the
// verdict is reproducible from source alone.
check_migrations :: proc(ast: Ast) -> Type_Error {
	for decl in ast.datas {
		if decl.has_migrate && type_name_is_live(ast, decl.migrate.from) {
			return .Migrate_From_Collision
		}
		for field in decl.fields {
			if !field.has_migrate {
				continue
			}
			if field.migrate.has_from {
				for other in decl.fields {
					if other.name == field.migrate.from {
						return .Migrate_From_Collision
					}
				}
			}
			if field.migrate.has_with {
				check_migrate_convert(ast, field) or_return
			}
		}
	}
	return .None
}

// check_index_paths enforces the §05 §3 @index/@spatial FieldPath rules over
// every query declaration — pure AST, like the layer registry and the @migrate
// admissibility checks, since both halves are membership rules the body sweep
// cannot see. The path head must name a thing the module declares (a thing or
// singleton — the index is INSTANCE-level, "a deterministic instance-level
// index over a thing's field", so a data/enum/signal head is the named
// Index_Unknown_Thing verdict like an undeclared name); the path member must
// name a field that thing's schema declares (Index_Unknown_Field otherwise).
// Walks the ordered ast slices only, never an env map, so the verdict is
// reproducible from source alone.
check_index_paths :: proc(ast: Ast) -> Type_Error {
	for query in ast.queries {
		for directive in query.indexes {
			thing, declared := thing_by_name(ast, directive.thing)
			if !declared {
				return .Index_Unknown_Thing
			}
			if !fields_declare(thing.fields, directive.field) {
				return .Index_Unknown_Field
			}
		}
	}
	return .None
}

// thing_by_name looks a declared thing/singleton up by name off the ordered
// ast.things slice — the §05 §3 index-path head's resolution domain.
thing_by_name :: proc(ast: Ast, name: string) -> (thing: Thing_Node, declared: bool) {
	for decl in ast.things {
		if decl.name == name {
			return decl, true
		}
	}
	return Thing_Node{}, false
}

// fields_declare reports whether a field list declares the named field — the
// §05 §3 index-path member's membership test, a linear scan over the
// source-ordered fields so the verdict never depends on map order.
fields_declare :: proc(fields: []Field_Decl, name: string) -> bool {
	for field in fields {
		if field.name == name {
			return true
		}
	}
	return false
}

// type_name_is_live reports whether the module currently declares a type under
// the given name — the live set a decl-level @migrate rename's prior name must
// not collide with. The set is the module's own declared types (data, enum,
// thing/singleton, signal), read off the ordered ast slices.
type_name_is_live :: proc(ast: Ast, name: string) -> bool {
	for decl in ast.datas {
		if decl.name == name {
			return true
		}
	}
	for decl in ast.enums {
		if decl.name == name {
			return true
		}
	}
	for decl in ast.things {
		if decl.name == name {
			return true
		}
	}
	for decl in ast.signals {
		if decl.name == name {
			return true
		}
	}
	return false
}

// check_migrate_convert verifies one field's @migrate `with:` conversion is
// admissible (spec §05 §6: a pure `fn(Old) -> New`): it names a fn this
// module declares (funpack fns are pure by construction, so the declaration
// is the purity evidence), takes exactly one parameter (the old value in),
// and returns the field's declared type (New out). Each deviation is its own
// named verdict so an agent repairs the exact mismatch. The return comparison
// is on the syntactic Type_Ref spelling — the same canonical rendering the
// artifact carries — since the surface has no type aliases to see through.
check_migrate_convert :: proc(ast: Ast, field: Field_Decl) -> Type_Error {
	for fn in ast.fns {
		if fn.name != field.migrate.with {
			continue
		}
		if len(fn.params) != 1 {
			return .Migrate_Convert_Arity
		}
		if type_ref_string(fn.return_type) != type_ref_string(field.type) {
			return .Migrate_Convert_Return
		}
		return .None
	}
	return .Migrate_Convert_Unknown
}

// layer_walk_body descends a statement body for Body record literals, recursing
// into an `if` guard's condition and nested block. Every expression position is
// walked so a Body buried in a list, a call argument, or a `with` value is still
// gated.
layer_walk_body :: proc(body: []Statement, registry: []string) -> Type_Error {
	for stmt in body {
		switch node in stmt {
		case Let_Node:
			layer_walk_expr(node.value, registry) or_return
		case Assert_Node:
			layer_walk_expr(node.expr, registry) or_return
		case Return_Node:
			layer_walk_expr(node.value, registry) or_return
		case If_Node:
			layer_walk_expr(node.cond, registry) or_return
			layer_walk_body(node.body, registry) or_return
		}
	}
	return .None
}

// layer_walk_expr descends one expression, validating any Body record literal's
// layer/mask fields and recursing into every sub-expression. It mirrors the Expr
// union arm-for-arm so a new expression form is a visible gap here, not a
// silently-unwalked branch (the same discipline as the gate's match walk).
layer_walk_expr :: proc(expr: Expr, registry: []string) -> Type_Error {
	switch e in expr {
	case ^Int_Lit_Expr, ^Fixed_Lit_Expr, ^String_Lit_Expr, ^Name_Expr:
		return .None
	case ^Call_Expr:
		layer_walk_expr(e.callee, registry) or_return
		for arg in e.args {
			layer_walk_expr(arg, registry) or_return
		}
	case ^Member_Expr:
		layer_walk_expr(e.receiver, registry) or_return
	case ^Variant_Expr:
		for arg in e.payload {
			layer_walk_expr(arg, registry) or_return
		}
		for field in e.fields {
			layer_walk_expr(field.value, registry) or_return
		}
	case ^Record_Expr:
		if e.type_name == "Body" {
			check_body_layers(e, registry) or_return
		}
		for field in e.fields {
			layer_walk_expr(field.value, registry) or_return
		}
	case ^List_Expr:
		for element in e.elements {
			layer_walk_expr(element, registry) or_return
		}
	case ^Lambda_Expr:
		layer_walk_expr(e.body, registry) or_return
	case ^Unary_Expr:
		layer_walk_expr(e.operand, registry) or_return
	case ^Binary_Expr:
		layer_walk_expr(e.lhs, registry) or_return
		layer_walk_expr(e.rhs, registry) or_return
	case ^With_Expr:
		layer_walk_expr(e.base, registry) or_return
		for field in e.fields {
			layer_walk_expr(field.value, registry) or_return
		}
	case ^Match_Expr:
		layer_walk_expr(e.scrutinee, registry) or_return
		for arm in e.arms {
			layer_walk_expr(arm.body, registry) or_return
		}
	case ^Tuple_Expr:
		for element in e.elements {
			layer_walk_expr(element, registry) or_return
		}
	case ^If_Expr:
		layer_walk_expr(e.cond, registry) or_return
		layer_walk_expr(e.then_branch, registry) or_return
		layer_walk_expr(e.else_branch, registry) or_return
	case ^Stub_Expr:
		// An expression-position hole's fallback is an expression position
		// like any other (the same rule check_layer_registry applies to a
		// body hole's fallback): a Body literal inside it is gated here, not
		// exempted by the hole. A bare hole hosts nothing.
		if e.has_fallback {
			layer_walk_expr(e.fallback, registry) or_return
		}
	case ^All_Expr:
		// The §08 §3 world read is a leaf — it hosts no sub-expression.
	}
	return .None
}

// check_body_layers validates a Body literal's `layer` and `mask` field values
// against the layer registry (spec §11 §5). `layer` is a single variant value
// (Layer::Wall); `mask` is a list of them ([Layer::Player, Layer::Crate]). Each
// variant referenced must be a registered layer; an unregistered one is the
// compile error. A non-variant value in these fields is left to the typing pass
// (it already rejected an ill-typed field) — this pass only adds the registry
// rule the field schema's nil type cannot express.
check_body_layers :: proc(e: ^Record_Expr, registry: []string) -> Type_Error {
	for field in e.fields {
		if field.name == "layer" {
			check_layer_value(field.value, registry) or_return
		}
		if field.name == "mask" {
			if list, is_list := field.value.(^List_Expr); is_list {
				for element in list.elements {
					check_layer_value(element, registry) or_return
				}
			}
		}
	}
	return .None
}

// check_layer_value rejects a single layer reference outside the registry. A
// layer value is a variant `Layer::Wall`, so only a Variant_Expr is checked
// against the registered set; any other expression shape is left to the typing
// pass (this pass owns only the registry membership rule).
check_layer_value :: proc(expr: Expr, registry: []string) -> Type_Error {
	variant, is_variant := expr.(^Variant_Expr)
	if !is_variant {
		return .None
	}
	if !name_in_set(variant.variant, registry) {
		return .Unregistered_Layer
	}
	return .None
}

// check_bodies types every top-level fn body and behavior step body against
// its parameters (spec §06 §3: a behavior's params are its reads, its return
// its writes). bindings()/setup() are top-level fns, so they ride this sweep.
// The index threads through so a body's param/return type naming a sibling
// module's type (a behavior step over View[Switch] where Switch is imported)
// resolves cross-module.
check_bodies :: proc(bindings: Bindings, env: Type_Env, index: Module_Index, ast: Ast, importer_root := "") -> Type_Error {
	for fn in ast.fns {
		// An `extern fn` (§26) has no body — its implementation is the engine's,
		// not the source's — so there is nothing to type. Its signature is still
		// resolved (resolve_env) and exported (collect_module_exports); only the
		// body-typing pass skips it.
		if fn.is_extern {
			continue
		}
		check_fn_body(bindings, env, index, fn, importer_root) or_return
	}
	for query in ast.queries {
		// A query body types exactly like a fn body — params seed the scope,
		// the declared `-> R` is the expected return (spec §08 §3: pure over
		// (version, params)) — so an ill-typed or unknown-field use inside it
		// surfaces the same named diagnostics a fn body gets. The grammar
		// admits no body-position hole on a query, so the synthesized node is
		// never holed. The query CONTEXT (in_query + the declared requirement
		// set) rides the ctx so `all[T]` and the spatial combinators resolve.
		check_query_body(bindings, env, index, query, importer_root) or_return
	}
	for behavior in ast.behaviors {
		check_fn_body(bindings, env, index, behavior.step, importer_root) or_return
	}
	return .None
}

// query_as_fn projects a query declaration onto the Fn_Node window
// check_fn_body types — name, params, declared return, statement body. A
// query is signature-and-body identical to a fn at the typing seam (the
// read-only/no-resource constraints are semantic layers above this window),
// so one body checker serves both and the two can never drift.
query_as_fn :: proc(query: Query_Node) -> Fn_Node {
	return Fn_Node {
		name = query.name,
		params = query.params,
		return_type = query.return_type,
		body = query.body,
		line = query.line,
	}
}

// check_fn_body types one fn/step body: it seeds a scope with the declared
// parameters as their resolved types, threads the declared return type as the
// body's expected_return, and types the statement sequence. The index resolves a
// param/return type naming a sibling user module's type (so a `setup() -> [Spawn]`
// or a `step(self: Door, switches: View[Switch])` whose element is imported
// grounds correctly). A §05 §2 typed hole standing in body position routes to
// check_stub_hole — there is no statement sequence to walk.
check_fn_body :: proc(bindings: Bindings, env: Type_Env, index: Module_Index, fn: Fn_Node, importer_root := "") -> Type_Error {
	ctx := fn_body_ctx(bindings, env, index, fn, importer_root)
	if fn.holed {
		return check_stub_hole(ctx, fn)
	}
	return check_statements(ctx, fn.body)
}

// check_query_body types one §08 §3 query body through the same param-seeded
// window a fn body rides (fn_body_ctx over the query_as_fn projection), with
// the QUERY CONTEXT set: in_query admits the world read `all[T]`, and the
// declared @index/@spatial requirement set rides query_indexes so the spatial
// combinators (within/nearest_first) resolve the field they measure.
check_query_body :: proc(bindings: Bindings, env: Type_Env, index: Module_Index, query: Query_Node, importer_root := "") -> Type_Error {
	ctx := fn_body_ctx(bindings, env, index, query_as_fn(query), importer_root)
	ctx.in_query = true
	ctx.query_indexes = query.indexes
	// §08 §3 value-param-only: a query is pure over (version, params) and
	// reads the world through `all[T]` alone, so a world handle (View/Ref), a
	// resource, or a function in its parameter list is the named diagnostic —
	// such a parameter would smuggle a read path (or unkeyable content) past
	// the (version, params) memo identity.
	for param in query.params {
		if type_outside_value_domain(ctx.scope[param.name]) {
			return .Query_Param_Not_Value
		}
	}
	return check_statements(ctx, query.body)
}

// type_outside_value_domain reports whether a resolved type carries any arm
// outside the §08 §3 query value domain: the read table View[T], the world
// handles Ref/Nav, the resources Input/Time/Rng/Bindings, or a function type
// (unkeyable by the (version, params) memo identity, unreceivable by a
// compiled signature). Containers (Option/List/Tuple) are walked so a wrapped
// handle cannot hide; ground scalars, user records/enums/things-as-values,
// and every other engine VALUE kind (handles like MeshHandle, command records)
// stay in the domain.
type_outside_value_domain :: proc(t: Type) -> bool {
	switch v in t {
	case Ground_Type:
		return false
	case ^Option_Type:
		return type_outside_value_domain(v.elem)
	case ^List_Type:
		return type_outside_value_domain(v.elem)
	case ^Tuple_Type:
		for elem in v.elements {
			if type_outside_value_domain(elem) {
				return true
			}
		}
		return false
	case ^Func_Type:
		return true
	case ^User_Type:
		return false
	case ^Engine_Type:
		#partial switch v.kind {
		case .View, .Ref, .Nav, .Input, .Time, .Rng, .Bindings:
			return true
		}
		return false
	}
	return false
}

// fn_body_ctx seeds the one body-sweep context both fn and query bodies type
// in: the declared parameters as their resolved types in a fresh scope, the
// declared `-> R` as expected_return, and the import/env/index triple threaded
// through for cross-module resolution.
fn_body_ctx :: proc(bindings: Bindings, env: Type_Env, index: Module_Index, fn: Fn_Node, importer_root := "") -> Check_Ctx {
	ctx := Check_Ctx {
		bindings        = bindings,
		env             = env,
		index           = index,
		scope           = make(Scope, context.temp_allocator),
		expected_return = resolve_type_ref(env, bindings, fn.return_type, index),
		importer_root   = importer_root,
	}
	for param in fn.params {
		ctx.scope[param.name] = resolve_type_ref(env, bindings, param.type, index)
	}
	return ctx
}

// check_stub_hole types a holed fn/step (spec §05 §2, P8): `@stub(T)` stands
// where the body would be, so the hole's declared T must unify with the fn's
// `-> R` ascription — a disagreeing `@stub(T)` is a Type_Mismatch, never
// silently accepted. That equality is the whole type seam: the signature
// stays intact (resolve_fn_signature records it body-blind), so every caller
// already typechecks against T through the unchanged Func_Type (call_check)
// rather than against the missing body. The `@stub(T, fallback)`
// approximation expression checks against the hole's T in the param-seeded
// scope — the decl's own environment — so a fallback that cannot produce T
// rejects here, before the evaluation stage ever runs it.
check_stub_hole :: proc(ctx: Check_Ctx, fn: Fn_Node) -> Type_Error {
	hole := resolve_type_ref(ctx.env, ctx.bindings, fn.hole_type, ctx.index)
	if !types_compatible(hole, ctx.expected_return) {
		return .Type_Mismatch
	}
	if fn.has_fallback {
		fallback := expr_check(ctx, fn.fallback) or_return
		if !types_compatible(fallback, hole) {
			return .Type_Mismatch
		}
	}
	return .None
}

// check_statements types a fn-body statement sequence: a let binds its
// inferred type into the scope, a return is checked against the body's
// expected return type, and an if early-return guard checks its condition is
// Bool and its guarded block under the same expected return.
check_statements :: proc(ctx: Check_Ctx, body: []Statement) -> Type_Error {
	ctx := ctx
	for stmt in body {
		switch node in stmt {
		case Let_Node:
			type := expr_check(ctx, node.value) or_return
			ctx.scope[node.name] = type
		case Return_Node:
			value := expr_check(ctx, node.value) or_return
			if !types_compatible(value, ctx.expected_return) {
				return .Type_Mismatch
			}
		case If_Node:
			cond := expr_check(ctx, node.cond) or_return
			if !is_ground(cond, .Bool) {
				return .Type_Mismatch
			}
			check_statements(ctx, node.body) or_return
		case Assert_Node:
			// An assert is a test-block statement; a fn body never holds one.
		}
	}
	return .None
}

// check_tests types every test block: a let binds its inferred type, an
// assert demands a Bool expression. The §04 name.step form and the closed
// return-form literals reach the same expr_check the bodies use. The index
// threads through so a test calling a cross-module fn (or constructing a
// sibling-module type) resolves it.
check_tests :: proc(bindings: Bindings, env: Type_Env, index: Module_Index, ast: Ast, importer_root := "") -> Type_Error {
	for test in ast.tests {
		ctx := Check_Ctx{bindings = bindings, env = env, index = index, scope = make(Scope, context.temp_allocator), importer_root = importer_root}
		for stmt in test.body {
			switch node in stmt {
			case Let_Node:
				type := expr_check(ctx, node.value) or_return
				ctx.scope[node.name] = type
			case Assert_Node:
				check_assert(ctx, node) or_return
			case Return_Node, If_Node:
				// Return/If are fn-body statements, never present in a test
				// block — the only statement sequence this sweep checks.
			}
		}
	}
	return .None
}

check_assert :: proc(ctx: Check_Ctx, node: Assert_Node) -> Type_Error {
	type := expr_check(ctx, node.expr) or_return
	if !is_ground(type, .Bool) {
		return .Assert_Not_Bool
	}
	return .None
}

expr_check :: proc(ctx: Check_Ctx, expr: Expr) -> (type: Type, err: Type_Error) {
	#partial switch e in expr {
	case ^Int_Lit_Expr:
		return Ground_Type.Int, .None
	case ^Fixed_Lit_Expr:
		return Ground_Type.Fixed, .None
	case ^String_Lit_Expr:
		// A string literal types as the engine String regardless of its
		// interpolation holes (spec §02 §2: the holes are retained verbatim;
		// splitting them is a lowering concern, not typing).
		return engine_type_of(.String), .None
	case ^Name_Expr:
		return name_check(ctx, e)
	case ^Unary_Expr:
		operand := expr_check(ctx, e.operand) or_return
		// `not` is a word operator carried as an Ident token (expr.odin): it
		// negates a Bool into a Bool — the `not contains(occ, c)` predicate body
		// snake's filter passes. Numeric negation `-x` keeps its numeric type.
		if e.op.kind == .Ident && e.op.text == "not" {
			if !is_ground(operand, .Bool) {
				return nil, .Type_Mismatch
			}
			return Ground_Type.Bool, .None
		}
		if e.op.kind != .Minus {
			return nil, .Unsupported_Expr
		}
		if !is_numeric_ground(operand) {
			return nil, .Type_Mismatch
		}
		return operand, .None
	case ^Binary_Expr:
		return binary_check(ctx, e)
	case ^Member_Expr:
		return member_check(ctx, e)
	case ^Record_Expr:
		return record_check(ctx, e)
	case ^List_Expr:
		return list_check(ctx, e)
	case ^Lambda_Expr:
		// Outside combinator position a lambda has no expected type to
		// infer params from — the opaque placeholder signature.
		return func_of(nil, nil), .None
	case ^Call_Expr:
		return call_check(ctx, e)
	case ^Variant_Expr:
		return variant_check(ctx, e)
	case ^With_Expr:
		return with_check(ctx, e)
	case ^Match_Expr:
		return match_check(ctx, e)
	case ^Tuple_Expr:
		return tuple_check(ctx, e)
	case ^If_Expr:
		return if_check(ctx, e)
	case ^Stub_Expr:
		return stub_expr_check(ctx, e)
	case ^All_Expr:
		return all_check(ctx, e)
	}
	return nil, .Unsupported_Expr
}

// all_check types the §08 §3 world read `all[T]`: admitted inside a query
// body alone (a query is the read path's only world-reading declaration —
// All_Outside_Query elsewhere), with T a declared thing/singleton (the table
// of rows; All_Unknown_Thing otherwise). The read yields the §08 §2 read
// table View[T] in stable Id order, so the whole existing combinator surface
// (fold/filter/first/map/len and the spatial combinators) composes over it
// through source_element exactly as over a behavior's View param.
all_check :: proc(ctx: Check_Ctx, e: ^All_Expr) -> (type: Type, err: Type_Error) {
	if !ctx.in_query {
		return nil, .All_Outside_Query
	}
	record, declared := ctx.env.records[e.thing]
	if !declared || record.kind != .Thing {
		return nil, .All_Unknown_Thing
	}
	return engine_type_of(.View, user_type_of(e.thing, .Thing)), .None
}

// stub_expr_check types an expression-position typed hole (spec §05 §2;
// grammar/fun.ebnf §15: StubExpr is an Atom): the hole ASCRIBES its declared
// T — the expression's type IS T, so the enclosing expression typechecks
// against the hole exactly as a caller typechecks against a holed
// declaration's intact signature (check_stub_hole). The optional fallback
// approximation checks against the hole's T in the scope at the hole's
// position — the enclosing declaration's param-seeded scope plus any earlier
// `let` bindings — mirroring the body-position fallback rule, so an ill-typed
// fallback is a Type_Mismatch here, before the evaluation stage ever runs it.
stub_expr_check :: proc(ctx: Check_Ctx, e: ^Stub_Expr) -> (type: Type, err: Type_Error) {
	hole := resolve_type_ref(ctx.env, ctx.bindings, e.hole_type, ctx.index)
	if e.has_fallback {
		fallback := expr_check(ctx, e.fallback) or_return
		if !types_compatible(fallback, hole) {
			return nil, .Type_Mismatch
		}
	}
	return hole, .None
}

// if_check types a value-producing if-expression (spec §02 §5): the condition
// must be Bool, and the two arm types must unify — the unified type is the
// if-expression's type, exactly like a two-armed match. Both arms are required
// by the parser (.Missing_Else), so this pass always sees a then AND an else; a
// disagreement between them is .Type_Mismatch (no implicit promotion). The else
// arm may itself be an If_Expr (an else-if chain), which types recursively
// through this same arm.
if_check :: proc(ctx: Check_Ctx, e: ^If_Expr) -> (type: Type, err: Type_Error) {
	cond := expr_check(ctx, e.cond) or_return
	if !is_ground(cond, .Bool) {
		return nil, .Type_Mismatch
	}
	then_type := expr_check(ctx, e.then_branch) or_return
	else_type := expr_check(ctx, e.else_branch) or_return
	if !types_compatible(then_type, else_type) {
		return nil, .Type_Mismatch
	}
	// A nil arm (the unknown) lets the other arm carry the type, mirroring the
	// match unification — types_compatible already accepted the pair.
	if then_type == nil {
		return else_type, .None
	}
	return then_type, .None
}

// tuple_check types a tuple expression `(a, b, …)` into a Tuple_Type over its
// positional element types (spec §04 §1: the `(value, next_rng)` return pair).
// Each element types independently — positions need not agree — so the
// RNG-threaded `(next, [Spawn(…)])` body checks against a declared
// `(Rng, [Spawn])` return position by position.
tuple_check :: proc(ctx: Check_Ctx, e: ^Tuple_Expr) -> (type: Type, err: Type_Error) {
	elements := make([]Type, len(e.elements), context.temp_allocator)
	for element, i in e.elements {
		elements[i] = expr_check(ctx, element) or_return
	}
	return tuple_of(elements), .None
}

// name_check types a bare name use: a scope binding (param/let/binder) first,
// then a module-let constant or top-level fn through the user environment,
// then an imported value constant. A type-position name or a behavior name is
// not a value on its own (it is only meaningful as a constructor head,
// variant head, or `.step` receiver), so it is Unsupported_Expr; a name no
// partition claims is Unresolved_Name.
name_check :: proc(ctx: Check_Ctx, e: ^Name_Expr) -> (type: Type, err: Type_Error) {
	// §02 §2 Bool literals: `true`/`false` ride as Ident tokens (the same
	// carriage `and`/`or` use) and are keywords — checked before the scope so
	// no binding can shadow them.
	if e.name == "true" || e.name == "false" {
		return Ground_Type.Bool, .None
	}
	if bound, found := ctx.scope[e.name]; found {
		return bound, .None
	}
	if term, found := env_term_name(ctx.env, e.name); found {
		#partial switch term.kind {
		case .Const:
			return term.type, .None
		case .Fn, .Query:
			// A bare fn name is a function value — its signature, the form
			// fold's accumulator argument (add_goal) takes. A query reads the
			// same way (spec §08 §3: callable, composing into callers).
			return term.signature, .None
		case .Behavior:
			// A behavior is only meaningful through its `.step` receiver.
			return nil, .Unsupported_Expr
		}
	}
	if binding, found := ctx.bindings.names[e.name]; found {
		if binding.kind == .Value {
			if value_type, typed := surface_value_type(e.name); typed {
				return value_type, .None
			}
		}
		// A bare name an import bound to a SIBLING user module's fn is a
		// function value exactly like the local-fn arm above — the form a
		// combinator argument takes across the module (or §30 package) edge.
		// A stdlib .Func binding carries no user signature, so the lookup
		// misses it and the fall-through below stands.
		if binding.kind == .Func {
			if signature, is_cross := module_call_signature(ctx.index, ctx.bindings, e.name); is_cross {
				return signature, .None
			}
		}
		// A type, module, or bare function name is not a value.
		return nil, .Unsupported_Expr
	}
	if env_declares(ctx.env, e.name) {
		// A type-position user name (a record/enum) binds but is not a value.
		return nil, .Unsupported_Expr
	}
	return nil, .Unresolved_Name
}

binary_check :: proc(ctx: Check_Ctx, e: ^Binary_Expr) -> (type: Type, err: Type_Error) {
	lhs := expr_check(ctx, e.lhs) or_return
	rhs := expr_check(ctx, e.rhs) or_return
	if e.op.kind == .Eq_Eq || e.op.kind == .Not_Eq {
		if !types_compatible(lhs, rhs) {
			return nil, .Type_Mismatch
		}
		return Ground_Type.Bool, .None
	}
	#partial switch e.op.kind {
	case .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		// Ordering compares two same-typed numeric sides into a Bool. A nil side
		// is the unknown that unifies (an Option::None-seeded fold's binder reads
		// nil), so the compare grounds on the CONCRETE side: at least one side must
		// be numeric, and the sides must unify (types_compatible treats nil as
		// unifying), mirroring the §02 nil-as-unknown convention the rest of the
		// type system uses.
		if !(is_numeric_ground(lhs) || is_numeric_ground(rhs)) || !types_compatible(lhs, rhs) {
			return nil, .Type_Mismatch
		}
		return Ground_Type.Bool, .None
	case .Plus, .Minus, .Star, .Slash, .Percent:
		// Arithmetic admits two same-typed numeric scalars, or a vector with
		// a numeric side (Vec2 * Fixed, Vec2 + Vec2) the kernel lowers — the
		// pong `advance` helper's `vel * dt` and `at + vel*dt`.
		return arithmetic_check(lhs, rhs)
	case .Ident:
		// `and`/`or` ride as Ident tokens; both sides must be Bool.
		if e.op.text == "and" || e.op.text == "or" {
			if !is_ground(lhs, .Bool) || !is_ground(rhs, .Bool) {
				return nil, .Type_Mismatch
			}
			return Ground_Type.Bool, .None
		}
	}
	return nil, .Unsupported_Expr
}

// arithmetic_check types `a op b` for the numeric and vector-numeric forms
// the §10 kernel lowers: two same-typed numeric scalars, a vector with a
// matching vector, or a vector scaled by a numeric scalar on either side.
// There is no Int→Fixed promotion — the two scalar sides must already agree.
// A nil side is the §02 unknown that unifies (an Option::None-seeded fold's
// binder reads nil, so `b - from` in arena's nearest_player has a nil `b`): the
// op grounds on the CONCRETE side, mirroring how types_compatible treats nil as
// unifying everywhere else.
arithmetic_check :: proc(lhs, rhs: Type) -> (type: Type, err: Type_Error) {
	// A nil (unknown) side grounds the op on the concrete side: `nil op X` and
	// `X op nil` both keep X. Both-nil keeps nil (still unknown).
	if lhs == nil {
		return rhs, .None
	}
	if rhs == nil {
		return lhs, .None
	}
	if is_numeric_ground(lhs) && types_compatible(lhs, rhs) {
		return lhs, .None
	}
	if is_vector_ground(lhs) {
		if types_compatible(lhs, rhs) {
			return lhs, .None
		}
		// A vector scaled by a fixed scalar keeps the vector type.
		if is_ground(rhs, .Fixed) {
			return lhs, .None
		}
	}
	if is_vector_ground(rhs) && is_ground(lhs, .Fixed) {
		return rhs, .None
	}
	return nil, .Type_Mismatch
}

// member_check types `receiver.member`: a value receiver exposes its fields
// (a user record's schema field, a Vec2/Vec3 component, an engine resource's
// member), while a Type-name receiver resolved through the surface selects an
// associated constant (Fixed.MAX, Quat.identity).
member_check :: proc(ctx: Check_Ctx, e: ^Member_Expr) -> (type: Type, err: Type_Error) {
	if recv, is_name := e.receiver.(^Name_Expr); is_name {
		// A whole-module handle receiver (`import assets`, then `assets.coin_sfx`)
		// selects an exported member of the sibling user module — a module-qualified
		// const grounds to its declared let type before any value path. A let const
		// member resolves through the index; any other exported member (a type, a fn)
		// or an UNKNOWN member of the handle's module rejects precisely here, the
		// user-module analogue of a member-group import's .Unknown_Member, so the
		// receiver is never re-typed as a value (a .Module handle is not a value).
		if member_type, handled, member_err := module_member_check(ctx, recv.name, e.member); handled {
			return member_type, member_err
		}
		// A Type-name receiver imported through the surface selects an
		// associated constant before any value path.
		if _, in_scope := ctx.scope[recv.name]; !in_scope {
			if _, is_term := env_term_name(ctx.env, recv.name); !is_term {
				if binding, imported := ctx.bindings.names[recv.name]; imported && binding.kind == .Type_Name {
					return associated_member(recv.name, e.member)
				}
			}
		}
	}
	// Every other receiver is a value: type it, then read the member off its
	// type.
	receiver := expr_check(ctx, e.receiver) or_return
	return field_member(ctx, receiver, e.member)
}

// module_member_check types `handle.member` where `handle` is a whole-module
// `.Module` binding of a sibling user module (the §19 `import assets` seam). It is
// the term-position cross-module access arm: a .Const member grounds to its
// declared let type (`assets.coin_sfx` → SoundHandle); a member the module exports
// but is not a const (a type, a fn) is .Unsupported_Expr (a module-qualified type
// or fn name is not a value here); a member the module does NOT export is the
// precise .Unknown_Member reject, closing the handle's member surface exactly as a
// member-group import closes its member list; a member a PACKAGE module exports
// but does not @expose is .Package_Private (spec §30 §6) — the handle route
// reaches an export with no importing declaration, so the package edge gates
// here exactly as resolve_user_import gates the import forms (one predicate,
// module_export_importable). Privacy fires BEFORE the kind check: a
// package-private const is refused for its privacy, never re-shaped into
// .Unsupported_Expr. handled = false when the receiver is
// not a user-module handle (a local binding, a stdlib type-name, a value receiver),
// leaving member_check's other arms untouched.
module_member_check :: proc(ctx: Check_Ctx, handle: string, member: string) -> (type: Type, handled: bool, err: Type_Error) {
	// A local binding of the handle name shadows the module handle (it is a value
	// receiver, not a module-qualified access) — never re-route those here.
	if _, in_scope := ctx.scope[handle]; in_scope {
		return nil, false, .None
	}
	kind, exported, handle_known, importable := module_member_kind(ctx.index, ctx.bindings, handle, member, ctx.importer_root)
	if !handle_known {
		return nil, false, .None
	}
	if !exported {
		return nil, true, .Unknown_Member
	}
	if !importable {
		return nil, true, .Package_Private
	}
	if kind != .Const {
		// An exported type or fn reached through `handle.NAME` is not a value.
		return nil, true, .Unsupported_Expr
	}
	const_type, found := module_const_type(ctx.index, ctx.bindings, handle, member)
	if !found {
		return nil, true, .Unknown_Member
	}
	return const_type, true, .None
}

// associated_member types a Type-name receiver's associated constant (a
// constructor is only meaningful applied, so it is Unsupported_Expr here).
associated_member :: proc(type_name: string, member: string) -> (type: Type, err: Type_Error) {
	associated, declared := surface_associated(type_name, member)
	if !declared {
		return nil, .Unsupported_Expr
	}
	if _, is_constructor := associated.(^Func_Type); is_constructor {
		return nil, .Unsupported_Expr
	}
	return associated, .None
}

// ctx_record_schema resolves a record type's field schema by name, the local env
// FIRST and the project-wide index second — so a CROSS-MODULE record (an imported
// Switch's `on`, a `Switch{…}` literal, a `with` over an imported record) reads
// its declared fields from the owning module's schema. A local declaration of the
// same name wins (the §02 collision check already rejected a local decl shadowing
// an import), and a name that is neither local nor a cross-module record is the
// caller's miss.
ctx_record_schema :: proc(ctx: Check_Ctx, name: string) -> (schema: Record_Schema, found: bool) {
	if record, declared := ctx.env.records[name]; declared {
		return record, true
	}
	return module_record_schema(ctx.index, ctx.bindings, name)
}

// field_member reads a member off a value's type: a user record's declared
// field, a Vec2/Vec3 component, or an engine resource's member (Time.dt).
field_member :: proc(ctx: Check_Ctx, receiver: Type, member: string) -> (type: Type, err: Type_Error) {
	switch r in receiver {
	case ^User_Type:
		if record, found := ctx_record_schema(ctx, r.name); found {
			if field, has := record_field_type(record, member); has {
				return field, .None
			}
		}
		return nil, .Type_Mismatch
	case Ground_Type:
		if r == .Vec2 && (member == "x" || member == "y") {
			return Ground_Type.Fixed, .None
		}
		if r == .Vec3 && (member == "x" || member == "y" || member == "z") {
			return Ground_Type.Fixed, .None
		}
		return nil, .Type_Mismatch
	case ^Engine_Type:
		// Time.dt and the like read through surface_engine_member; the §11/§24
		// engine RECORDS (Body, Settings, AccessOpts) and the outcome signals'
		// `result` field read through surface_engine_member_record.
		if field, found := surface_engine_member(r, member); found {
			return field, .None
		}
		if field, found := surface_engine_member_record(r, member); found {
			return field, .None
		}
		return nil, .Type_Mismatch
	case ^Option_Type, ^List_Type, ^Tuple_Type, ^Func_Type:
		// None of these expose a named member — a tuple is destructured by a
		// match pattern (spec §02 §5), never read by `.field`.
		return nil, .Type_Mismatch
	}
	return nil, .Unsupported_Expr
}

// record_field_type reads a declared field's type from a record schema by
// name — a linear lookup, so field order never reaches the verdict.
record_field_type :: proc(schema: Record_Schema, name: string) -> (type: Type, found: bool) {
	for field in schema.fields {
		if field.name == name {
			return field.type, true
		}
	}
	return nil, false
}

// record_check types a record literal: Vec2/Vec3 lower to their ground type
// with Fixed components, and a user thing/data/signal literal checks each
// field value against its declared schema type and yields the record's
// nominal handle.
record_check :: proc(ctx: Check_Ctx, e: ^Record_Expr) -> (type: Type, err: Type_Error) {
	if binding, imported := ctx.bindings.names[e.type_name]; imported {
		if binding.kind != .Type_Name {
			return nil, .Unsupported_Expr
		}
		switch e.type_name {
		case "Vec2":
			ground_record_check(ctx, e, {"x", "y"}) or_return
			return Ground_Type.Vec2, .None
		case "Vec3":
			ground_record_check(ctx, e, {"x", "y", "z"}) or_return
			return Ground_Type.Vec3, .None
		}
		// A §11/§24 engine record literal (Body{…}, Save{…}, ApplySettings{…}):
		// each named field checks against the closed surface schema, and the
		// result is the record's engine type (the Body value, the Save command).
		if result, fields, is_record := surface_engine_record(e.type_name); is_record {
			engine_record_check(ctx, e, fields) or_return
			return result, .None
		}
		// A CROSS-MODULE user record literal (`Switch{pos:…, on:…}` over a Switch
		// imported from arena_world): the name binds as a sibling-module .Type_Name,
		// so its field schema comes from the project-wide index, not the local env.
		if record, declared := module_record_schema(ctx.index, ctx.bindings, e.type_name); declared {
			user_record_check(ctx, e, record) or_return
			return user_type_of(record.type_name, record.kind), .None
		}
		return nil, .Unsupported_Expr
	}
	if record, declared := ctx_record_schema(ctx, e.type_name); declared {
		user_record_check(ctx, e, record) or_return
		return user_type_of(record.type_name, record.kind), .None
	}
	if env_declares(ctx.env, e.type_name) {
		return nil, .Unsupported_Expr
	}
	return nil, .Unresolved_Name
}

// user_record_check checks each field value of a user record literal against
// its declared schema type and demands every named field belong to the
// schema. A missing required field is not rejected here — defaults make a
// field omittable (spec §03 §1), and field presence is a downstream concern.
user_record_check :: proc(ctx: Check_Ctx, e: ^Record_Expr, schema: Record_Schema) -> Type_Error {
	for field in e.fields {
		declared, known := record_field_type(schema, field.name)
		if !known {
			return .Type_Mismatch
		}
		got := expr_check(ctx, field.value) or_return
		if !types_compatible(got, declared) {
			return .Type_Mismatch
		}
	}
	return .None
}

// engine_record_check checks each field value of a §11/§24 engine record
// literal against its closed surface schema (surface_engine_record) and demands
// every named field belong to it. Like user_record_check, a missing field is not
// rejected here — defaults make a field omittable (spec §11 §2: mass/restitution
// /friction/sensor/impulse default), and field presence is downstream. A field
// whose schema type is the nil unknown (a Body's layer/mask) accepts any value
// shape; types_compatible's nil arm passes it, and the layer-registry gate
// validates its variant.
engine_record_check :: proc(ctx: Check_Ctx, e: ^Record_Expr, fields: []Surface_Field) -> Type_Error {
	for field in e.fields {
		want, known := surface_field_type(fields, field.name)
		if !known {
			return .Type_Mismatch
		}
		got := expr_check(ctx, field.value) or_return
		if !types_compatible(got, want) {
			return .Type_Mismatch
		}
	}
	return .None
}

// ground_record_check demands every field name belong to the engine ground
// record's component set and every component expression be Fixed.
ground_record_check :: proc(ctx: Check_Ctx, e: ^Record_Expr, allowed: []string) -> Type_Error {
	for field in e.fields {
		if !name_in_set(field.name, allowed) {
			return .Type_Mismatch
		}
		got := expr_check(ctx, field.value) or_return
		if !is_ground(got, .Fixed) {
			return .Type_Mismatch
		}
	}
	return .None
}

name_in_set :: proc(name: string, set: []string) -> bool {
	for candidate in set {
		if candidate == name {
			return true
		}
	}
	return false
}

// list_check types a list literal: every element must agree, and the element
// type is the first concrete one (nil for the empty list). The closed §04
// return-form lists ([Spawn], [Draw], [Goal]) are list literals whose element
// type the typing pass infers from their constructors.
list_check :: proc(ctx: Check_Ctx, e: ^List_Expr) -> (type: Type, err: Type_Error) {
	element_type: Type
	for element in e.elements {
		got := expr_check(ctx, element) or_return
		if !types_compatible(element_type, got) {
			return nil, .Type_Mismatch
		}
		if element_type == nil {
			element_type = got
		}
	}
	return list_of(element_type), .None
}

// with_check types a record-update `base with { field: v, … }` (spec §02 §5):
// the base must be a user record, every updated field must belong to its
// schema, every value must match the field's declared type, and the result is
// the same record type (an update never changes the nominal type).
with_check :: proc(ctx: Check_Ctx, e: ^With_Expr) -> (type: Type, err: Type_Error) {
	base := expr_check(ctx, e.base) or_return
	// An engine-record base (§24 `settings with {access: …}`, `access with
	// {reduce_motion: …}`) updates against the closed surface schema; a user
	// record updates against its declared schema. Both keep the base's nominal
	// type — an update never changes it.
	if engine, is_engine := base.(^Engine_Type); is_engine {
		_, fields, has_schema := surface_engine_record(engine_kind_name(engine.kind))
		if !has_schema {
			return nil, .Type_Mismatch
		}
		engine_record_check(ctx, e_with_as_record(e), fields) or_return
		return base, .None
	}
	user, is_user := base.(^User_Type)
	if !is_user {
		return nil, .Type_Mismatch
	}
	// The base may be a local OR a cross-module record (a chase step returns
	// `self with {pos:…}` over a Hunter imported from arena_world), so the schema
	// resolves through the local env first and the project-wide index second.
	record, declared := ctx_record_schema(ctx, user.name)
	if !declared {
		return nil, .Type_Mismatch
	}
	for field in e.fields {
		want, known := record_field_type(record, field.name)
		if !known {
			return nil, .Type_Mismatch
		}
		got := expr_check(ctx, field.value) or_return
		if !types_compatible(got, want) {
			return nil, .Type_Mismatch
		}
	}
	return base, .None
}

// e_with_as_record adapts a With_Expr's update fields into a Record_Expr so the
// engine-record field check (engine_record_check, shared with literal
// construction) reads one field set. A `with` carries the same Record_Field
// shape as a literal; only the base differs, which with_check already typed.
e_with_as_record :: proc(e: ^With_Expr) -> ^Record_Expr {
	adapter := new(Record_Expr, context.temp_allocator)
	adapter.fields = e.fields
	return adapter
}

// match_check types a match expression (spec §02 §5): the scrutinee is typed,
// each arm's pattern binders bind against the scrutinee's variant payloads,
// each arm body is typed under those binders, and every arm body must agree —
// the unified arm type is the match's type. Exhaustiveness is the gate's job
// (gates.odin), not this pass's. An arm's binders overlay the shared scope
// only for that arm's body, then are removed, so one arm's binder never leaks
// into the next.
match_check :: proc(ctx: Check_Ctx, e: ^Match_Expr) -> (type: Type, err: Type_Error) {
	ctx := ctx
	scrutinee := expr_check(ctx, e.scrutinee) or_return
	result: Type
	for arm in e.arms {
		check_pattern_arity(arm.pattern, scrutinee) or_return
		binders, types := pattern_binders(ctx.env, arm.pattern, scrutinee)
		saved := overlay_scope(&ctx.scope, binders, types)
		body, body_err := expr_check(ctx, arm.body)
		restore_scope(&ctx.scope, binders, saved)
		if body_err != .None {
			return nil, body_err
		}
		if !types_compatible(result, body) {
			return nil, .Type_Mismatch
		}
		if result == nil {
			result = body
		}
	}
	return result, .None
}

// check_pattern_arity rejects a tuple match pattern whose positional arity
// disagrees with its Tuple-typed scrutinee (spec §02 §5): a `(a, b)` pattern
// over a 3-tuple, or a `(a, b, c)` pattern over a 2-tuple, can never bind
// coherently, so it is .Tuple_Pattern_Arity rather than a silent nil-bound
// position. The check recurses into each sub-pattern against the matching
// tuple element, so a nested tuple `((x, y), z)` is arity-checked at every
// level. A tuple pattern over a non-tuple (or nil/unknown) scrutinee is left to
// the resolver/gate — this pass owns only the arity rule when both sides are
// tuples; a non-tuple pattern (variant, wildcard, bare binder) has no arity to
// disagree on and passes through.
check_pattern_arity :: proc(pattern: Pattern, scrutinee: Type) -> Type_Error {
	if pattern.kind != .Tuple {
		return .None
	}
	tuple, is_tuple := scrutinee.(^Tuple_Type)
	if !is_tuple {
		// The scrutinee's tuple shape is unknown here — arity is the gate's /
		// resolver's concern, not a precise mismatch this pass can claim.
		return .None
	}
	if len(pattern.elements) != len(tuple.elements) {
		return .Tuple_Pattern_Arity
	}
	for sub, i in pattern.elements {
		check_pattern_arity(sub, tuple.elements[i]) or_return
	}
	return .None
}

// pattern_binders computes an arm pattern's binder names and their types against
// the scrutinee, recursing through a tuple pattern. A Variant_Binds over Option
// binds the single payload to the option's element; a Bare_Binder binds its name
// to the whole scrutinee position's type; a Tuple pattern over a Tuple scrutinee
// zips position by position, recursing each sub-pattern against its element type
// and concatenating the binders in left-to-right order (so the
// `(Option::Some(cell), next)` arm binds `cell` to the option's element and
// `next` to the second tuple element). A bare-variant or wildcard pattern binds
// nothing; a user-enum variant carries no payload on this surface, so it
// contributes none either.
pattern_binders :: proc(env: Type_Env, pattern: Pattern, scrutinee: Type) -> (names: []string, types: []Type) {
	out_names := make([dynamic]string, 0, 4, context.temp_allocator)
	out_types := make([dynamic]Type, 0, 4, context.temp_allocator)
	collect_pattern_binders(env, pattern, scrutinee, &out_names, &out_types)
	return out_names[:], out_types[:]
}

// collect_pattern_binders appends one pattern's binders and their types onto the
// shared accumulators, recursing into a tuple pattern's positions against the
// matching tuple scrutinee element. A tuple pattern over a Tuple scrutinee is
// already arity-checked by check_pattern_arity (run per arm in match_check), so
// a disagreeing arity never reaches here; an unknown scrutinee shape (a nil
// position, or a tuple pattern over a non-tuple scrutinee) binds the names to
// nil — the typing pass leaves an unresolvable binder as the nil unknown rather
// than rejecting, since exhaustiveness/shape is the gate's and resolver's
// concern.
collect_pattern_binders :: proc(
	env: Type_Env,
	pattern: Pattern,
	scrutinee: Type,
	names: ^[dynamic]string,
	types: ^[dynamic]Type,
) {
	switch pattern.kind {
	case .Wildcard, .Bare_Variant:
		// No binders.
	case .Bare_Binder:
		// A bare binder binds the whole position to the scrutinee's type.
		for binder in pattern.binders {
			append(names, binder)
			append(types, scrutinee)
		}
	case .Variant_Binds:
		// A variant-with-payload binds through its one payload sub-pattern (grammar
		// §13: each payload position is a full Pattern): the position's type is the
		// Option's element (Option::Some(v)) or the §21 §3 user tagged-union variant's
		// declared payload (AppMsg::Hud(m), SettingsMsg::SetVolume(v)), and the
		// sub-pattern recurses against it — a Bare_Binder binds `m`/`v` to that type,
		// a nested Bare_Variant (AppMsg::Hud(HudMsg::Coin)) binds nothing. The surface
		// carries one payload per variant, so the single sub-pattern takes the
		// position's type.
		position_type: Type
		if option, is_option := scrutinee.(^Option_Type); is_option {
			position_type = option.elem
		} else if schema, declared := env.enums[pattern.type_name]; declared {
			payload, _ := enum_variant_payload(schema, pattern.variant)
			position_type = payload
		}
		for sub in pattern.elements {
			collect_pattern_binders(env, sub, position_type, names, types)
		}
	case .Struct_Binds:
		// A struct-payload field-pun (`Shape2::Box{size}`) binds each field name
		// to a value of that field's declared type. The pattern carries its own
		// type_name/variant, so the variant's struct-payload schema resolves
		// directly from the surface (e.g. Shape2::Box's `size: Vec2`); a binder
		// naming a field outside the schema, or a variant with no schema, binds to
		// the nil unknown (the unresolvable-position rule above) rather than
		// rejecting here — arm-shape validity is the gate's concern.
		_, payload_fields, has_schema := surface_struct_variant(pattern.type_name, pattern.variant)
		for binder in pattern.binders {
			binder_type: Type
			if has_schema {
				if field_type, known := surface_field_type(payload_fields, binder); known {
					binder_type = field_type
				}
			}
			append(names, binder)
			append(types, binder_type)
		}
	case .Tuple:
		// A tuple pattern zips against a tuple scrutinee position by position.
		tuple, is_tuple := scrutinee.(^Tuple_Type)
		for sub, i in pattern.elements {
			element: Type
			if is_tuple && i < len(tuple.elements) {
				element = tuple.elements[i]
			}
			collect_pattern_binders(env, sub, element, names, types)
		}
	}
}

// call_check types a call. A method/step receiver routes to method_check; a
// free-name callee resolves through the let scope, the user environment, and
// the imported surface to its signature or combinator rule.
call_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if member, is_method := e.callee.(^Member_Expr); is_method {
		return method_check(ctx, member, e)
	}
	name, is_name := e.callee.(^Name_Expr)
	if !is_name {
		return nil, .Unsupported_Expr
	}
	if _, let_bound := ctx.scope[name.name]; let_bound {
		// Calling a let/param-bound fn value stays fail-closed even when the
		// binding carries a REAL declared signature (a §02 §3 fn-typed
		// parameter now resolves to a Func_Type with a row): admitting the
		// call would type-admit an invocation the evaluator cannot run — a
		// first-class fn value has no runtime representation — violating
		// "funpack does not grammar-include what it cannot run". Pinned by
		// fixture; lifting it is the first-class-fn-values story, not a
		// signature-resolution concern.
		return nil, .Unsupported_Expr
	}
	// A call to a user-declared fn or query checks its arguments against the
	// recorded signature (resolve.odin) — a query call composes into its
	// caller exactly like a fn call (spec §08 §3); a behavior is not callable
	// as a bare name.
	if term, found := env_term_name(ctx.env, name.name); found {
		if (term.kind == .Fn || term.kind == .Query) && term.signature != nil {
			check_args(ctx, e, term.signature.params) or_return
			return term.signature.result, .None
		}
		return nil, .Unsupported_Expr
	}
	binding, found := ctx.bindings.names[name.name]
	if !found {
		return nil, .Unresolved_Name
	}
	if binding.kind == .Type_Name {
		// A §04 command constructor applied (Spawn(thing)).
		if signature, is_command := surface_command(name.name); is_command {
			command := signature.(^Func_Type)
			check_args(ctx, e, command.params) or_return
			return command.result, .None
		}
		return nil, .Unsupported_Expr
	}
	if binding.kind != .Func {
		return nil, .Type_Mismatch
	}
	// A call to a fn imported from a SIBLING user module (arena_game's setup calls
	// the arena seam's `arena_spawns()`): the project-wide index carries the
	// imported fn's resolved signature, so the call checks its args against the
	// cross-module params and yields the cross-module result type. The stdlib
	// surface owns no name a user module exports, so this arm precedes the
	// combinator/overload arms (a user fn is never a combinator).
	if signature, is_cross := module_call_signature(ctx.index, ctx.bindings, name.name); is_cross {
		check_args(ctx, e, signature.params) or_return
		return signature.result, .None
	}
	if comb_type, handled, comb_err := combinator_call_check(ctx, name.name, e); handled {
		return comb_type, comb_err
	}
	overloads, has_signature := surface_signatures(name.name)
	if !has_signature {
		return nil, .Unsupported_Expr
	}
	return overloads_check(ctx, e, overloads)
}

// combinator_call_check routes the call-site-inferred stdlib combinators — the
// names surface_signatures returns found = false for, since their parameters
// depend on the call site, not a fixed table (surface.odin). handled is false
// for a name that is not a combinator, so the caller falls through to the fixed
// overload table. Each rule reads its source's element type (a List[T] or a
// §08 View[T], via source_element) and types the lambda/predicate argument
// against the inferred element row (combinator_check), the same inference
// fold/first use.
combinator_call_check :: proc(ctx: Check_Ctx, name: string, e: ^Call_Expr) -> (type: Type, handled: bool, err: Type_Error) {
	switch name {
	case "fold":
		t, fe := fold_check(ctx, e)
		return t, true, fe
	case "first":
		t, fe := first_check(ctx, e)
		return t, true, fe
	case "within":
		t, we := spatial_combinator_check(ctx, e, true)
		return t, true, we
	case "nearest_first":
		t, ne := spatial_combinator_check(ctx, e, false)
		return t, true, ne
	case "or_else":
		t, oe := or_else_check(ctx, e)
		return t, true, oe
	case "map":
		t, me := map_check(ctx, e)
		return t, true, me
	case "filter":
		t, fe := filter_check(ctx, e)
		return t, true, fe
	case "concat":
		t, ce := concat_check(ctx, e)
		return t, true, ce
	case "contains":
		t, ce := contains_check(ctx, e)
		return t, true, ce
	case "prepend":
		t, pe := prepend_check(ctx, e)
		return t, true, pe
	case "init":
		t, ie := init_check(ctx, e)
		return t, true, ie
	case "is_empty":
		t, ie := is_empty_check(ctx, e)
		return t, true, ie
	case "len":
		t, le := len_check(ctx, e)
		return t, true, le
	case "get":
		t, ge := get_check(ctx, e)
		return t, true, ge
	case "pick":
		t, pe := pick_check(ctx, e)
		return t, true, pe
	case "grid_cells":
		t, ge := grid_cells_check(ctx, e)
		return t, true, ge
	}
	return nil, false, .None
}

// map_check types map(source, fn) (spec §08): the source is a List[T] or a
// View[T], the function is (T) -> R inferred from the element type, and the
// result is a list of the function's result type — `map(foods, fn(f){ … })`
// over a View[Food] yields a list of whatever the lambda returns. The lambda's
// result type is inferred by typing its body against the element-typed param.
map_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	elem, ok := source_element(source)
	if !ok {
		return nil, .Type_Mismatch
	}
	result := combinator_result(ctx, e.args[1], {elem}) or_return
	return list_of(result), .None
}

// filter_check types filter(source, pred) (spec §08): the source is a List[T] or
// a View[T], the predicate is (T) -> Bool inferred from the element type, and the
// result is a list of the element type (a View filtered yields a list, per the
// read-side surface) — `filter(foods, fn(f){ f.cell == self.head })` over a
// View[Food] yields [Food], and `filter(all_cells(), pred)` over [Cell] yields
// [Cell].
filter_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	elem, ok := source_element(source)
	if !ok {
		return nil, .Type_Mismatch
	}
	combinator_check(ctx, e.args[1], {elem}, Ground_Type.Bool) or_return
	return list_of(elem), .None
}

// concat_check types concat(a, b) (spec §08): both arguments are lists, their
// element types unify, and the result is a list of that element — `concat(
// cells(snake), map(foods, …))` joins two [Cell] into one. A nil element on
// either side unifies, so a concat with an empty list keeps the other's element.
concat_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	left := expr_check(ctx, e.args[0]) or_return
	right := expr_check(ctx, e.args[1]) or_return
	left_list, left_ok := left.(^List_Type)
	right_list, right_ok := right.(^List_Type)
	if !left_ok || !right_ok {
		return nil, .Type_Mismatch
	}
	if !types_compatible(left_list.elem, right_list.elem) {
		return nil, .Type_Mismatch
	}
	elem := left_list.elem
	if elem == nil {
		elem = right_list.elem
	}
	return list_of(elem), .None
}

// contains_check types contains(list, elem) (spec §08): a List[T] and a value of
// the element type, yielding Bool — `contains(self.body, self.head)` tests a
// [Cell] against a Cell. The element value's type must unify with the list's.
contains_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	list_type := expr_check(ctx, e.args[0]) or_return
	value := expr_check(ctx, e.args[1]) or_return
	list, is_list := list_type.(^List_Type)
	if !is_list {
		return nil, .Type_Mismatch
	}
	if !types_compatible(list.elem, value) {
		return nil, .Type_Mismatch
	}
	return Ground_Type.Bool, .None
}

// prepend_check types prepend(elem, list) (spec §08): a value and a List[T] whose
// element unifies with it, yielding a [T] with the value pushed to the front —
// `prepend(snake.head, snake.body)` puts a Cell at the head of a [Cell]. The
// result element type is the unified element (the value's type when the list is
// the nil-element empty list).
prepend_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	value := expr_check(ctx, e.args[0]) or_return
	list_type := expr_check(ctx, e.args[1]) or_return
	list, is_list := list_type.(^List_Type)
	if !is_list {
		return nil, .Type_Mismatch
	}
	if !types_compatible(list.elem, value) {
		return nil, .Type_Mismatch
	}
	elem := list.elem
	if elem == nil {
		elem = value
	}
	return list_of(elem), .None
}

// init_check types init(list) (spec §08): a List[T] yielding the same [T] with
// its last element dropped — `init(extended)` drops the snake's tail cell. The
// element type is unchanged.
init_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 1 {
		return nil, .Type_Mismatch
	}
	list_type := expr_check(ctx, e.args[0]) or_return
	list, is_list := list_type.(^List_Type)
	if !is_list {
		return nil, .Type_Mismatch
	}
	return list_of(list.elem), .None
}

// is_empty_check types is_empty(source) (spec §08): a List[T] or a View[T]
// yielding Bool — `is_empty(eaten)` tests the inbound [Eaten] signal list. The
// source's element type is irrelevant to the result, only that it is a read
// source.
is_empty_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 1 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	if _, ok := source_element(source); !ok {
		return nil, .Type_Mismatch
	}
	return Ground_Type.Bool, .None
}

// len_check types len(source) (spec §08): a List[T] or a View[T] yielding the
// element count as an Int — yard's `tally` reads `len(done)` over the inbound
// [Delivered] signal list to fold the tick's deliveries into the running tally.
// Like is_empty, only that the argument is a read source matters; the element
// type is irrelevant to the Int result.
len_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 1 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	if _, ok := source_element(source); !ok {
		return nil, .Type_Mismatch
	}
	return Ground_Type.Int, .None
}

// get_check types get(source, i) (spec §08 engine.list): a List[T] or a View[T]
// and an Int index, yielding Option[T] — total, None on out-of-range. The hud
// `get(App{}.settings_view().volume_presets, 1)` reads the second preset row off
// a [SettingsPresetRow], so the element type drives the Option payload.
get_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	index := expr_check(ctx, e.args[1]) or_return
	elem, ok := source_element(source)
	if !ok {
		return nil, .Type_Mismatch
	}
	if !is_ground(index, .Int) {
		return nil, .Type_Mismatch
	}
	return option_of(elem), .None
}

// pick_check types pick(list, rng) (spec §04 §1, engine.rand): a List[T] and the
// threaded Rng handle, yielding the draw pair (Option[T], Rng) — the first
// result is an option of the list's element (None when the list is empty), the
// second the advanced RNG stream. The match in `replenish`/`setup` destructures
// this tuple. The second argument must be the Rng handle.
pick_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	list_type := expr_check(ctx, e.args[0]) or_return
	rng := expr_check(ctx, e.args[1]) or_return
	list, is_list := list_type.(^List_Type)
	if !is_list {
		return nil, .Type_Mismatch
	}
	if !is_engine(rng, .Rng) {
		return nil, .Type_Mismatch
	}
	return tuple_of({option_of(list.elem), engine_type_of(.Rng)}), .None
}

// grid_cells_check types grid_cells(w, h, builder) (spec, engine.grid): two Int
// grid dimensions and a builder fn(x, y) -> Cell, yielding a list of whatever
// the builder returns ([Cell] for `grid_cells(GRID.size.x, GRID.size.y, fn(x, y){
// Cell{x: x, y: y} })`). The element type is call-site-inferred from the
// builder's result — the Cell is the user's, not the engine's — so admission is
// the Func table row and the typing is here, like the list combinators. The
// builder's two params infer as Int (the grid coordinates).
grid_cells_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 3 {
		return nil, .Type_Mismatch
	}
	width := expr_check(ctx, e.args[0]) or_return
	height := expr_check(ctx, e.args[1]) or_return
	if !is_ground(width, .Int) || !is_ground(height, .Int) {
		return nil, .Type_Mismatch
	}
	cell := combinator_result(ctx, e.args[2], {Ground_Type.Int, Ground_Type.Int}) or_return
	return list_of(cell), .None
}

// combinator_result types a combinator's function argument against an inferred
// parameter row whose RESULT type is unknown and must be read off the function,
// not checked against an expected one (map's mapper, grid_cells's builder). A
// literal lambda infers its parameters from the row, types its body in a child
// scope holding exactly them, and yields the body's type as the result; a bare
// fn value (or other function-typed expression) yields its recorded result. This
// is the result-inferring sibling of combinator_check, which checks against a
// known expected result (a predicate's Bool, fold's accumulator).
combinator_result :: proc(ctx: Check_Ctx, arg: Expr, params: []Type) -> (result: Type, err: Type_Error) {
	ctx := ctx
	if lambda, is_lambda := arg.(^Lambda_Expr); is_lambda {
		if len(lambda.params) != len(params) {
			return nil, .Type_Mismatch
		}
		saved := overlay_scope(&ctx.scope, lambda.params, params)
		body, body_err := expr_check(ctx, lambda.body)
		restore_scope(&ctx.scope, lambda.params, saved)
		if body_err != .None {
			return nil, body_err
		}
		return body, .None
	}
	got := expr_check(ctx, arg) or_return
	func, is_func := got.(^Func_Type)
	if !is_func {
		return nil, .Type_Mismatch
	}
	return func.result, .None
}

// fold is (source, A, (A, T) -> A) -> A: T unifies from the source's element
// type, A from the init, and the accumulator function is either a literal
// lambda inferred as (A, T) or a bare fn whose recorded signature is checked
// against (A, T) -> A — the form tally's fold(goals, self, add_goal) takes. The
// source is a List[T] OR a §08 View[T] (arena's nearest_player folds
// `players: View[Player]` into an Option[Vec2]), so the element comes through
// source_element, the same read both first and map use.
fold_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 3 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	init := expr_check(ctx, e.args[1]) or_return
	elem, ok := source_element(source)
	if !ok {
		return nil, .Type_Mismatch
	}
	combinator_check(ctx, e.args[2], {init, elem}, init) or_return
	return init, .None
}

// first has two forms (spec §08): first(view, pred) over a View[T] yields
// Option[T] where pred is (T) -> Bool, and first(list) over a List[T] yields
// Option[T]. The element type drives the inferred predicate parameter, the
// same combinator inference fold uses extended to a one-parameter predicate.
first_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) == 1 {
		source := expr_check(ctx, e.args[0]) or_return
		elem, ok := source_element(source)
		if !ok {
			return nil, .Type_Mismatch
		}
		return option_of(elem), .None
	}
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	elem, ok := source_element(source)
	if !ok {
		return nil, .Type_Mismatch
	}
	combinator_check(ctx, e.args[1], {elem}, Ground_Type.Bool) or_return
	return option_of(elem), .None
}

// or_else is (Option[T], T) -> T (spec §26): it unwraps an Option to its element
// or falls back to a default, the form arena's nearest_player uses
// (`or_else(best, from)` over an Option[Vec2] best). The fallback (the second arg)
// drives T — it is always a concrete value, while the Option may be the
// element-unknown Option[nil] from an Option::None fold init — so the rule reads
// T off the fallback, requires the first arg to be an Option whose element unifies
// with T, and yields T. A non-Option first arg or a fallback that does not match
// the Option's element is a Type_Mismatch.
or_else_check :: proc(ctx: Check_Ctx, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 2 {
		return nil, .Type_Mismatch
	}
	opt_type := expr_check(ctx, e.args[0]) or_return
	fallback := expr_check(ctx, e.args[1]) or_return
	option, is_option := opt_type.(^Option_Type)
	if !is_option {
		return nil, .Type_Mismatch
	}
	// The Option's element must unify with the fallback (a nil element — the
	// Option::None placeholder — unifies with any fallback, mirroring the other
	// combinators' nil-element handling).
	if !types_compatible(option.elem, fallback) {
		return nil, .Type_Mismatch
	}
	return fallback, .None
}

// spatial_combinator_check types the §08 §3 spatial combinators over the
// runtime kernel's pinned read shape: `within(source, origin, r) -> [T]`
// (every row whose declared @spatial field lies within the fixed-point radius
// of origin, source order kept) and `nearest_first(source, origin) -> [T]`
// (ascending kernel distance, stable — the Id tiebreak rides the source's
// stable Id order). The source is a View[T]/[T] whose element T is a declared
// thing; the field MEASURED is the one the ENCLOSING query's @spatial(T.f)
// declaration names — exactly one must match T (the named missing/ambiguous
// verdicts otherwise; outside a query no requirement exists, so the missing
// verdict covers that position too). The origin must carry the declared
// field's type, and that field must be a kernel-measurable vector (Vec2/Vec3
// — the §10 distance domain); the radius is Fixed. Whether the declaration
// itself is required/used is the structural index gate's verdict, upstream —
// this rule owns the field resolution and the value types.
spatial_combinator_check :: proc(ctx: Check_Ctx, e: ^Call_Expr, with_radius: bool) -> (type: Type, err: Type_Error) {
	arity := with_radius ? 3 : 2
	if len(e.args) != arity {
		return nil, .Type_Mismatch
	}
	source := expr_check(ctx, e.args[0]) or_return
	elem, elem_ok := source_element(source)
	if !elem_ok {
		return nil, .Type_Mismatch
	}
	thing, is_user := elem.(^User_Type)
	if !is_user || thing.kind != .Thing {
		return nil, .Type_Mismatch
	}
	field, resolve_err := spatial_requirement_field(ctx, thing.name)
	if resolve_err != .None {
		return nil, resolve_err
	}
	field_type, has_field := thing_field_type(ctx.env, thing.name, field)
	if !has_field || !is_vector_ground(field_type) {
		// A requirement naming a non-vector field has no kernel distance —
		// the §10 measure is defined over Vec2/Vec3 lanes alone.
		return nil, .Type_Mismatch
	}
	origin := expr_check(ctx, e.args[1]) or_return
	if !types_compatible(origin, field_type) {
		return nil, .Type_Mismatch
	}
	if with_radius {
		radius := expr_check(ctx, e.args[2]) or_return
		if !is_ground(radius, .Fixed) {
			return nil, .Type_Mismatch
		}
	}
	return list_of(elem), .None
}

// spatial_requirement_field resolves which field the enclosing query's
// @spatial declarations measure for one thing: exactly one declaration must
// name the thing — zero is the missing-requirement verdict (also every
// non-query position, which can declare none), several the ambiguous one.
spatial_requirement_field :: proc(ctx: Check_Ctx, thing: string) -> (field: string, err: Type_Error) {
	found := false
	for directive in ctx.query_indexes {
		if directive.kind != .Spatial || directive.thing != thing {
			continue
		}
		if found {
			return "", .Spatial_Requirement_Ambiguous
		}
		field = directive.field
		found = true
	}
	if !found {
		return "", .Spatial_Requirement_Missing
	}
	return field, .None
}

// thing_field_type reads one declared field's resolved type off a thing's
// schema — a linear scan over the source-ordered field list, the
// determinism-stable lookup the membership checks use.
thing_field_type :: proc(env: Type_Env, thing: string, field: string) -> (type: Type, ok: bool) {
	record, declared := env.records[thing]
	if !declared {
		return nil, false
	}
	for schema_field in record.fields {
		if schema_field.name == field {
			return schema_field.type, true
		}
	}
	return nil, false
}

// source_element reads the element type of a read source — a View[T] read
// table or a List[T] — the two forms first/fold iterate over.
source_element :: proc(source: Type) -> (elem: Type, ok: bool) {
	if view, is_view := source.(^Engine_Type); is_view && view.kind == .View {
		return view.elem, true
	}
	if list, is_list := source.(^List_Type); is_list {
		return list.elem, true
	}
	return nil, false
}

// combinator_check types a combinator's function argument against an expected
// parameter row and result. A literal lambda infers its parameters from the
// row and types its body in a child scope holding exactly them; a bare fn
// value (or another function-typed expression) is checked structurally
// against the expected signature.
combinator_check :: proc(ctx: Check_Ctx, arg: Expr, params: []Type, result: Type) -> Type_Error {
	ctx := ctx
	if lambda, is_lambda := arg.(^Lambda_Expr); is_lambda {
		if len(lambda.params) != len(params) {
			return .Type_Mismatch
		}
		// The lambda is a closure: its body sees the enclosing scope (the
		// paddle_bounce predicate reads `self`) with the inferred parameters
		// overlaid for the body, then restored — so a parameter shadowing an
		// enclosing name never erases that name once the body is typed.
		saved := overlay_scope(&ctx.scope, lambda.params, params)
		body, body_err := expr_check(ctx, lambda.body)
		restore_scope(&ctx.scope, lambda.params, saved)
		if body_err != .None {
			return body_err
		}
		if !types_compatible(body, result) {
			return .Type_Mismatch
		}
		return .None
	}
	got := expr_check(ctx, arg) or_return
	if !types_compatible(got, func_of(params, result)) {
		return .Type_Mismatch
	}
	return .None
}

// Saved_Binding records a name's prior scope state so a shadowing overlay can
// be undone exactly: present carries the prior type, or marks the name absent
// so restore deletes the overlay rather than reviving a binding that was never
// there.
Saved_Binding :: struct {
	type:    Type,
	present: bool,
}

// overlay_scope binds each name to its overlay type, returning the prior state
// of every name so restore_scope can undo the overlay. Names and types are
// positional — types[i] is bound to names[i].
overlay_scope :: proc(scope: ^Scope, names: []string, types: []Type) -> []Saved_Binding {
	saved := make([]Saved_Binding, len(names), context.temp_allocator)
	for name, i in names {
		prior, present := scope[name]
		saved[i] = Saved_Binding{type = prior, present = present}
		scope[name] = types[i]
	}
	return saved
}

// restore_scope undoes overlay_scope: a name that had a prior binding regains
// it, and a name that was absent before the overlay is removed.
restore_scope :: proc(scope: ^Scope, names: []string, saved: []Saved_Binding) {
	for name, i in names {
		if saved[i].present {
			scope[name] = saved[i].type
		} else {
			delete_key(scope, name)
		}
	}
}

// overloads_check types the arguments once and admits the call when the
// argument row matches one overload's parameters exactly.
overloads_check :: proc(ctx: Check_Ctx, e: ^Call_Expr, overloads: []Type) -> (type: Type, err: Type_Error) {
	args := make([]Type, len(e.args), context.temp_allocator)
	for arg, i in e.args {
		args[i] = expr_check(ctx, arg) or_return
	}
	for overload in overloads {
		signature, is_func := overload.(^Func_Type)
		if !is_func || len(signature.params) != len(args) {
			continue
		}
		matches := true
		for want, i in signature.params {
			if !types_compatible(args[i], want) {
				matches = false
				break
			}
		}
		if matches {
			return signature.result, .None
		}
	}
	return nil, .Type_Mismatch
}

check_args :: proc(ctx: Check_Ctx, e: ^Call_Expr, signature: []Type) -> Type_Error {
	if len(e.args) != len(signature) {
		return .Type_Mismatch
	}
	for want, i in signature {
		// A declared fn-typed parameter (spec §02 §3: `pred: fn(T) -> Bool`)
		// checks a literal lambda argument through the combinator inference
		// mold: the lambda's parameters infer from the declared row and its
		// body must yield the declared result — exactly how the stdlib
		// combinators check theirs (combinator_check). Only a REAL declared
		// signature routes here (nil params is the opaque placeholder, which
		// has no row to infer from); a non-lambda argument keeps the
		// structural judgment below.
		if func, is_func := want.(^Func_Type); is_func && func.params != nil {
			if _, is_lambda := e.args[i].(^Lambda_Expr); is_lambda {
				combinator_check(ctx, e.args[i], func.params, func.result) or_return
				continue
			}
		}
		got := expr_check(ctx, e.args[i]) or_return
		if !types_compatible(got, want) {
			return .Type_Mismatch
		}
	}
	return .None
}

// method_check types receiver.member(args). A Type-name receiver resolved
// through the surface selects an associated constructor (Quat.axis_angle) or
// a static builder entry (Bindings.empty()); a behavior-name receiver selects
// its reserved `.step` signature (the §04 name.step test-invocation form); any
// other receiver is a value whose methods the surface keys by its type.
method_check :: proc(ctx: Check_Ctx, callee: ^Member_Expr, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if recv, is_name := callee.receiver.(^Name_Expr); is_name {
		if _, in_scope := ctx.scope[recv.name]; !in_scope {
			if static, handled, static_err := static_method_check(ctx, recv.name, callee.member, e); handled {
				return static, static_err
			}
		}
	}
	receiver := expr_check(ctx, callee.receiver) or_return
	return value_method_check(ctx, receiver, callee.member, e)
}

// static_method_check handles a method whose receiver names a declaration,
// not a value: a behavior's `.step`, a Type-name surface constructor, or a
// Type-name static builder. handled is false when the receiver is not one of
// these, so the caller falls through to the value-method path.
static_method_check :: proc(
	ctx: Check_Ctx,
	recv_name: string,
	member: string,
	e: ^Call_Expr,
) -> (
	type: Type,
	handled: bool,
	err: Type_Error,
) {
	if term, found := env_term_name(ctx.env, recv_name); found {
		// The §04 name.step(args) form: a behavior reaches its step signature
		// through its own name key (resolve.odin).
		if term.kind == .Behavior && member == "step" && term.signature != nil {
			if arg_err := check_args(ctx, e, term.signature.params); arg_err != .None {
				return nil, true, arg_err
			}
			return term.signature.result, true, .None
		}
		return nil, true, .Unsupported_Expr
	}
	binding, imported := ctx.bindings.names[recv_name]
	if !imported || binding.kind != .Type_Name {
		return nil, false, .None
	}
	if static, found := surface_static_method(recv_name, member); found {
		signature := static.(^Func_Type)
		if arg_err := check_args(ctx, e, signature.params); arg_err != .None {
			return nil, true, arg_err
		}
		return signature.result, true, .None
	}
	// A Type-name associated constructor (Quat.axis_angle).
	associated, declared := surface_associated(recv_name, member)
	if !declared {
		return nil, true, .Unsupported_Expr
	}
	signature, is_constructor := associated.(^Func_Type)
	if !is_constructor {
		return nil, true, .Unsupported_Expr
	}
	if arg_err := check_args(ctx, e, signature.params); arg_err != .None {
		return nil, true, arg_err
	}
	return signature.result, true, .None
}

// value_method_check types a method off a typed value receiver, in the §02 §4
// resolution order: (1) UFCS — a top-level user fn whose first param has the
// receiver's type, called with the receiver as that argument (App{}.pause_view(),
// self.hud_view()); then (2) an engine value method — View.map (the §21 §3
// element-inferred re-tag) before the fixed-signature surface table (Sound/Audio
// builders, View.class/when, Input queries); then (3) a ground type's method (the
// Quat set). UFCS is tried first so a user projection fn shadows nothing — a
// receiver type has no surface method of the same name on this surface.
value_method_check :: proc(ctx: Check_Ctx, receiver: Type, member: string, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if ufcs, handled, ufcs_err := ufcs_method_check(ctx, receiver, member, e); handled {
		return ufcs, ufcs_err
	}
	if engine, is_engine := receiver.(^Engine_Type); is_engine {
		// §21 §3 View.map(into) re-tags every message a View[A] can emit through
		// into: fn(A) -> B, yielding View[B] — the element B is read off the function
		// argument's result, so it is element-inferred here, not a fixed-signature
		// surface row (the result type depends on the call site).
		if engine.kind == .View && member == "map" {
			return view_map_check(ctx, engine, e)
		}
		if signature, found := surface_engine_method(engine, member); found {
			method := signature.(^Func_Type)
			check_args(ctx, e, method.params) or_return
			return method.result, .None
		}
		return nil, .Unsupported_Expr
	}
	method, declared := surface_method(receiver, member)
	if !declared {
		return nil, .Unsupported_Expr
	}
	signature, is_func := method.(^Func_Type)
	if !is_func {
		return nil, .Unsupported_Expr
	}
	check_args(ctx, e, signature.params) or_return
	return signature.result, .None
}

// ufcs_method_check types the §02 §4 UFCS call `recv.f(args)` → `f(recv, args)`:
// a top-level user fn whose first parameter's type unifies with the receiver is
// called with the receiver prepended to the arguments. handled is false when no
// such user fn exists (the caller falls through to engine/ground methods). The
// hud projections (hud_view/pause_view/settings_view, each `fn(self: App)`) are
// reached this way as App{}.pause_view() / self.hud_view(). A user fn whose first
// param does NOT match the receiver is not a UFCS candidate, so it falls through.
ufcs_method_check :: proc(ctx: Check_Ctx, receiver: Type, member: string, e: ^Call_Expr) -> (type: Type, handled: bool, err: Type_Error) {
	term, found := env_term_name(ctx.env, member)
	if !found || term.kind != .Fn || term.signature == nil || len(term.signature.params) == 0 {
		return nil, false, .None
	}
	if !types_compatible(receiver, term.signature.params[0]) {
		return nil, false, .None
	}
	// Check the remaining arguments against the fn's tail parameters (the
	// receiver fills the first), then yield the fn's result.
	tail := term.signature.params[1:]
	if len(e.args) != len(tail) {
		return nil, true, .Type_Mismatch
	}
	for want, i in tail {
		got := expr_check(ctx, e.args[i]) or_return
		if !types_compatible(got, want) {
			return nil, true, .Type_Mismatch
		}
	}
	return term.signature.result, true, .None
}

// view_map_check types View[A].map(into) (spec §21 §3): the single argument is a
// re-tag function fn(A) -> B (the Elm Html.map primitive — AppMsg::Hud is the
// variant-as-function value fn(HudMsg) -> AppMsg the router passes), and the
// result is View[B], B read off the function's result. The function's parameter
// is the receiver's element A; a literal lambda infers it, and a
// variant-as-function value carries its own fn type.
view_map_check :: proc(ctx: Check_Ctx, view: ^Engine_Type, e: ^Call_Expr) -> (type: Type, err: Type_Error) {
	if len(e.args) != 1 {
		return nil, .Type_Mismatch
	}
	result := combinator_result(ctx, e.args[0], {view.elem}) or_return
	return engine_type_of(.View, result), .None
}

// variant_check types an enum-variant value. Option carries the evaluable
// Some/None; a user enum yields its nominal handle (a bare variant or a
// struct-payload constructor like [Goal{…}]'s element); an engine enum yields
// its engine handle (Color::White, PlayerId::P1); a struct-payload engine
// variant (Draw::Rect{…}) checks its fields against the surface schema.
variant_check :: proc(ctx: Check_Ctx, e: ^Variant_Expr) -> (type: Type, err: Type_Error) {
	if e.has_fields {
		return struct_variant_check(ctx, e)
	}
	if binding, imported := ctx.bindings.names[e.type_name]; imported {
		if binding.kind != .Type_Name {
			return nil, .Unsupported_Expr
		}
		if e.type_name == "Option" {
			return option_variant_check(ctx, e)
		}
		if engine, found := surface_enum_variant(e.type_name, e.variant); found {
			if e.has_payload {
				return nil, .Unsupported_Expr
			}
			return engine, .None
		}
		// A CROSS-MODULE user enum (spec §15: every top-level declaration is
		// importable): the imported `Screen`/`AppMsg` enum's variant used as a
		// value resolves its variant set + payloads through the project-wide index,
		// the variant-value analogue of module_record_schema for an imported record
		// literal. Typed by the same enum_variant_value_check as a local enum, so a
		// `Screen::Pause` value, an `AppMsg::Hud` variant-as-function value, and an
		// `AppMsg::Hud(m)` construction type identically whichever module declared
		// the enum.
		if enum_schema, found := module_enum_schema(ctx.index, ctx.bindings, e.type_name); found {
			return enum_variant_value_check(ctx, e, enum_schema)
		}
		return nil, .Unsupported_Expr
	}
	if enum_schema, declared := ctx.env.enums[e.type_name]; declared {
		return enum_variant_value_check(ctx, e, enum_schema)
	}
	if env_declares(ctx.env, e.type_name) {
		return nil, .Unsupported_Expr
	}
	return nil, .Unresolved_Name
}

// enum_variant_value_check types one user-enum variant used as a VALUE against
// its resolved Enum_Schema — the shared body the local-env and cross-module
// (index) variant-value paths both run, so a local `Screen::Pause` and an
// imported `Screen::Pause` type identically (spec §15: a declaration's module of
// origin is invisible at the use site). Three forms (spec §21 §3): a nullary
// variant is the enum value itself; a tagged construction `AppMsg::Hud(m)` checks
// its single payload argument against the variant's declared payload type and
// yields the enum; a payload variant named WITHOUT its payload is the
// variant-as-function value `AppMsg::Hud == fn(HudMsg) -> AppMsg` the
// `.map(AppMsg::Hud)` re-tag passes through.
enum_variant_value_check :: proc(ctx: Check_Ctx, e: ^Variant_Expr, enum_schema: Enum_Schema) -> (type: Type, err: Type_Error) {
	if !name_in_set(e.variant, enum_schema.variants) {
		return nil, .Type_Mismatch
	}
	payload, has_payload := enum_variant_payload(enum_schema, e.variant)
	enum_type := user_type_of(e.type_name, .Enum)
	if e.has_payload {
		// A §21 §3 tagged-union construction: AppMsg::Hud(m), SettingsMsg::
		// SetVolume(50). The variant must declare a single tuple payload, and the
		// argument must match its declared type; the result is the enum.
		if !has_payload || len(e.payload) != 1 {
			return nil, .Type_Mismatch
		}
		arg := expr_check(ctx, e.payload[0]) or_return
		if !types_compatible(arg, payload) {
			return nil, .Type_Mismatch
		}
		return enum_type, .None
	}
	// A bare variant reference. A nullary variant is the value itself; a payload
	// variant named WITHOUT its payload is the §21 §3 variant-as-function value
	// AppMsg::Hud == fn(HudMsg) -> AppMsg (the form .map(AppMsg::Hud) re-tags a
	// child screen's messages through).
	if has_payload {
		return func_of({payload}, enum_type), .None
	}
	return enum_type, .None
}

// option_variant_check types Option::Some(v) into Option[typeof v] and
// Option::None into the unknown-element Option.
option_variant_check :: proc(ctx: Check_Ctx, e: ^Variant_Expr) -> (type: Type, err: Type_Error) {
	switch e.variant {
	case "Some":
		if !e.has_payload || len(e.payload) != 1 {
			return nil, .Unsupported_Expr
		}
		payload := expr_check(ctx, e.payload[0]) or_return
		return option_of(payload), .None
	case "None":
		if e.has_payload {
			return nil, .Unsupported_Expr
		}
		return option_of(nil), .None
	}
	return nil, .Unsupported_Expr
}

// struct_variant_check types a struct-payload engine-enum variant
// (Draw::Rect{…}, Draw::Text{…}, spec §20): every named field must belong to
// the surface schema and match its declared type; the result is the variant's
// engine command type.
struct_variant_check :: proc(ctx: Check_Ctx, e: ^Variant_Expr) -> (type: Type, err: Type_Error) {
	result, fields, found := surface_struct_variant(e.type_name, e.variant)
	if !found {
		return nil, .Unsupported_Expr
	}
	for field in e.fields {
		want, known := surface_field_type(fields, field.name)
		if !known {
			return nil, .Type_Mismatch
		}
		got := expr_check(ctx, field.value) or_return
		if !types_compatible(got, want) {
			return nil, .Type_Mismatch
		}
	}
	return result, .None
}

// surface_field_type reads an engine struct-variant field's declared type by
// name — a linear lookup, so field order never reaches the verdict.
surface_field_type :: proc(fields: []Surface_Field, name: string) -> (type: Type, found: bool) {
	for field in fields {
		if field.name == name {
			return field.type, true
		}
	}
	return nil, false
}
