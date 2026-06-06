// The user-declaration resolver: it lifts every top-level §06/§07
// declaration's name into a first-class environment that sits alongside the
// imported stdlib surface (surface.odin), so a user thing/data/enum/signal,
// a module-level `let` constant, and a top-level fn/behavior are all
// in-scope names the typecheck stage can bind against. The pass records
// each declaration's type schema — a record's field name→type map, an
// enum's variant set, a let's declared type, a fn's parameter/return
// signature, a behavior's reserved `step` signature keyed for the §04
// `name.step(args)` test-invocation form. It enforces the §02 one-name-one-
// meaning rule across the user and imported namespaces (a user name
// colliding with an import, or two user decls of the same name, is a
// resolution error) and resolves field/parameter `Type_Ref`s to the
// checker's semantic Type where the name is known. This is name-and-schema
// only: no behavior body is typed and no call site is checked — that is the
// typing pass's job.
package funpack

// Record_Schema is the field name→type table of a thing/singleton/data/
// signal declaration (spec §03 §1, §06 §1). Field order is the source
// order; a defaulted field carries has_default so a literal may omit it
// (the typing pass's concern, recorded here for it).
Record_Schema :: struct {
	type_name: string,
	kind:      User_Kind,
	fields:    []Field_Schema,
}

Field_Schema :: struct {
	name:        string,
	type:        Type, // nil when the field's Type_Ref names nothing yet resolvable
	has_default: bool,
}

// Enum_Schema is the variant set of an enum declaration (spec §03 §2). role
// is the `enum Name: Kind` ascription ("" when absent) — the §03 §4 role
// kind (e.g. `enum Steer: Axis`); variants is the declared variant names in
// source order, the closed set the exhaustiveness gate proves coverage
// against once it is registered (gates.odin).
Enum_Schema :: struct {
	type_name: string,
	role:      string,
	variants:  []string,
}

// Term_Schema records a value-level name: a module-level `let` constant
// (its declared type), a top-level fn, or a behavior's reserved `step`
// entry point. signature is the fn/step function type; for a `let` it is
// the declared value type and is_func is false.
Term_Schema :: struct {
	name:      string,
	kind:      Term_Kind,
	type:      Type, // a `let`'s declared value type; nil for a fn/behavior
	signature: ^Func_Type, // a fn/step signature; nil for a `let`
	target:    string, // a behavior's `on Thing` target; "" otherwise
}

Term_Kind :: enum {
	Const,    // module-level `let NAME: T = expr`
	Fn,       // top-level `fn name(…) -> R`
	Behavior, // `behavior name on Thing { fn step(…) … }`, keyed for name.step
}

// Type_Env is the resolved user-declaration environment: the names a source
// declares, partitioned into type-position names (records and enums) and
// term-position names (constants, fns, behaviors). Both maps are insert-
// and-lookup only — never iterated (the determinism tripwire) — mirroring
// Bindings (surface.odin). all_names is the union of every declared name,
// used only by the one-name-one-meaning collision check and never read for
// resolution.
Type_Env :: struct {
	records: map[string]Record_Schema,
	enums:   map[string]Enum_Schema,
	terms:   map[string]Term_Schema,
}

// resolve_env walks the parsed declarations and builds the user
// environment over them, enforcing one-name-one-meaning against the
// imported surface and within the user namespace. It runs after
// resolve_imports so a user name shadowing an import is caught here. Field
// and parameter Type_Refs resolve against this same environment plus the
// imports, so a forward reference (a `data` field typed by a `thing`
// declared later) still resolves — the whole type namespace is collected
// before any ref is resolved.
resolve_env :: proc(ast: Ast, bindings: Bindings) -> (env: Type_Env, err: Type_Error) {
	env.records = make(map[string]Record_Schema, context.temp_allocator)
	env.enums = make(map[string]Enum_Schema, context.temp_allocator)
	env.terms = make(map[string]Term_Schema, context.temp_allocator)

	// Pass 1 — collect every declared name into its slot, rejecting a
	// collision with an import or an earlier user decl. Names are interned
	// before any Type_Ref is resolved so forward references between user
	// types resolve in pass 2.
	collect_type_names(&env, ast, bindings) or_return
	collect_term_names(&env, ast, bindings) or_return

	// Pass 2 — resolve each declaration's field/parameter/return Type_Refs
	// against the now-complete type namespace and the imports, filling the
	// recorded schemas.
	resolve_schemas(&env, ast, bindings)
	return env, .None
}

// collect_type_names interns thing/singleton/data/enum/signal names into
// the type partition. Each name is checked against the imports and the
// already-interned user names first: a clash is Name_Collision (spec §02).
collect_type_names :: proc(env: ^Type_Env, ast: Ast, bindings: Bindings) -> Type_Error {
	for decl in ast.things {
		claim_type_name(env, decl.name, bindings) or_return
		env.records[decl.name] = Record_Schema {
			type_name = decl.name,
			kind      = .Thing,
		}
	}
	for decl in ast.datas {
		claim_type_name(env, decl.name, bindings) or_return
		env.records[decl.name] = Record_Schema {
			type_name = decl.name,
			kind      = .Data,
		}
	}
	for decl in ast.signals {
		claim_type_name(env, decl.name, bindings) or_return
		env.records[decl.name] = Record_Schema {
			type_name = decl.name,
			kind      = .Signal,
		}
	}
	for decl in ast.enums {
		claim_type_name(env, decl.name, bindings) or_return
		variants := make([]string, len(decl.variants), context.temp_allocator)
		for variant, i in decl.variants {
			variants[i] = variant.name
		}
		env.enums[decl.name] = Enum_Schema {
			type_name = decl.name,
			role      = decl.kind,
			variants  = variants,
		}
	}
	return .None
}

// collect_term_names interns module-let, fn, and behavior names into the
// term partition. A behavior is keyed by its own name; the `name.step`
// test-invocation form (spec §04) reaches its step signature through this
// key, so the behavior name is the term, not a synthetic `name.step`
// string.
collect_term_names :: proc(env: ^Type_Env, ast: Ast, bindings: Bindings) -> Type_Error {
	for decl in ast.lets {
		claim_term_name(env, decl.name, bindings) or_return
		env.terms[decl.name] = Term_Schema{name = decl.name, kind = .Const}
	}
	for decl in ast.fns {
		claim_term_name(env, decl.name, bindings) or_return
		env.terms[decl.name] = Term_Schema{name = decl.name, kind = .Fn}
	}
	for decl in ast.behaviors {
		claim_term_name(env, decl.name, bindings) or_return
		env.terms[decl.name] = Term_Schema {
			name   = decl.name,
			kind   = .Behavior,
			target = decl.target,
		}
	}
	return .None
}

// claim_type_name rejects a type name that already names an imported
// surface member or a user declaration in any partition. The type and term
// namespaces share one flat scope (spec §02: one name, one meaning), so a
// type may not collide with a term either.
claim_type_name :: proc(env: ^Type_Env, name: string, bindings: Bindings) -> Type_Error {
	if name_taken(env, name, bindings) {
		return .Name_Collision
	}
	return .None
}

claim_term_name :: proc(env: ^Type_Env, name: string, bindings: Bindings) -> Type_Error {
	if name_taken(env, name, bindings) {
		return .Name_Collision
	}
	return .None
}

// name_taken reports whether a name already binds — to an imported surface
// member or to any user declaration already interned. The prelude is part
// of bindings, so a user type named `Option` collides with the prelude
// just as one named `Vec2` collides with an import.
name_taken :: proc(env: ^Type_Env, name: string, bindings: Bindings) -> bool {
	if _, imported := bindings.names[name]; imported {
		return true
	}
	if _, is_record := env.records[name]; is_record {
		return true
	}
	if _, is_enum := env.enums[name]; is_enum {
		return true
	}
	if _, is_term := env.terms[name]; is_term {
		return true
	}
	return false
}

// resolve_schemas fills the field/parameter/return types of every recorded
// schema, resolving each declaration's Type_Refs against the complete
// namespace. It is total over the AST and records nil for a ref it cannot
// resolve yet — the typing pass refines those, never this one.
resolve_schemas :: proc(env: ^Type_Env, ast: Ast, bindings: Bindings) {
	for decl in ast.things {
		schema := env.records[decl.name]
		schema.fields = resolve_field_schemas(env^, bindings, decl.fields)
		env.records[decl.name] = schema
	}
	for decl in ast.datas {
		schema := env.records[decl.name]
		schema.fields = resolve_field_schemas(env^, bindings, decl.fields)
		env.records[decl.name] = schema
	}
	for decl in ast.signals {
		schema := env.records[decl.name]
		schema.fields = resolve_field_schemas(env^, bindings, decl.fields)
		env.records[decl.name] = schema
	}
	for decl in ast.lets {
		term := env.terms[decl.name]
		term.type = resolve_type_ref(env^, bindings, decl.type)
		env.terms[decl.name] = term
	}
	for decl in ast.fns {
		term := env.terms[decl.name]
		term.signature = resolve_fn_signature(env^, bindings, decl.params, decl.return_type)
		env.terms[decl.name] = term
	}
	for decl in ast.behaviors {
		term := env.terms[decl.name]
		term.signature = resolve_fn_signature(env^, bindings, decl.step.params, decl.step.return_type)
		env.terms[decl.name] = term
	}
}

// resolve_field_schemas resolves one record's field list into the recorded
// schema: each field keeps its name, has_default flag, and best-effort
// resolved type.
resolve_field_schemas :: proc(env: Type_Env, bindings: Bindings, fields: []Field_Decl) -> []Field_Schema {
	out := make([]Field_Schema, len(fields), context.temp_allocator)
	for field, i in fields {
		out[i] = Field_Schema {
			name        = field.name,
			type        = resolve_type_ref(env, bindings, field.type),
			has_default = field.has_default,
		}
	}
	return out
}

// resolve_fn_signature builds a fn/step Func_Type from its parameter and
// return Type_Refs. The parameter types are the behavior's reads (spec §06
// §3); typing the body against them is the typing pass's job.
resolve_fn_signature :: proc(env: Type_Env, bindings: Bindings, params: []Param_Decl, return_type: Type_Ref) -> ^Func_Type {
	param_types := make([]Type, len(params), context.temp_allocator)
	for param, i in params {
		param_types[i] = resolve_type_ref(env, bindings, param.type)
	}
	node := new(Func_Type, context.temp_allocator)
	node.params = param_types
	node.result = resolve_type_ref(env, bindings, return_type)
	return node
}

// resolve_type_ref maps a syntactic Type_Ref (parser.odin) to the checker's
// semantic Type, consulting the ground types, the user environment, the
// engine ground records (Vec2/Vec3), and the parameterized Option/List
// heads. A name that resolves to nothing concrete yet — an imported engine
// type with no checker ground (View, Input, Spawn), or a generic over one —
// returns nil: the resolver records the schema slot without forcing a type
// the typing pass owns.
resolve_type_ref :: proc(env: Type_Env, bindings: Bindings, ref: Type_Ref) -> Type {
	// A list type `[T]` is the head "[]" with one element argument.
	if ref.name == "[]" {
		if len(ref.args) == 1 {
			return list_of(resolve_type_ref(env, bindings, ref.args[0]))
		}
		return nil
	}
	// A tuple type `(T, U, …)` is the head "()" with its positional element
	// types as args (spec §04 §1: the `(value, next_rng)` return pair). Each
	// position resolves like any other ref; the tuple node carries them in order.
	if ref.name == "()" {
		elements := make([]Type, len(ref.args), context.temp_allocator)
		for arg, i in ref.args {
			elements[i] = resolve_type_ref(env, bindings, arg)
		}
		return tuple_of(elements)
	}
	if ref.name == "Option" && len(ref.args) == 1 {
		return option_of(resolve_type_ref(env, bindings, ref.args[0]))
	}
	// View[T] is the §08 read table over an element type; the element
	// resolves like any other ref (a user thing for View[Paddle]).
	if ref.name == "View" && len(ref.args) == 1 {
		return engine_type_of(.View, resolve_type_ref(env, bindings, ref.args[0]))
	}
	if len(ref.args) == 0 {
		if ground, is_ground := ground_type_name(ref.name); is_ground {
			return ground
		}
		if record, is_record := env.records[ref.name]; is_record {
			return user_type_of(record.type_name, record.kind)
		}
		if _, is_enum := env.enums[ref.name]; is_enum {
			return user_type_of(ref.name, .Enum)
		}
		if engine, is_engine := engine_type_name(ref.name); is_engine {
			return engine
		}
	}
	// A ref naming nothing the checker grounds — an engine type with no
	// handle (View's bare head, an axis-role kind) or any other unresolved
	// ref: the schema slot stays nil for the typing pass.
	return nil
}

// engine_type_name maps the bare engine/stdlib type-name spellings the
// typing pass grounds to their Engine_Type handle (spec §04/§08/§20/§23).
// View is omitted: it is only ever parameterized (View[T]) and is grounded
// by the View[T] arm above.
engine_type_name :: proc(name: string) -> (type: Type, found: bool) {
	switch name {
	case "Spawn":
		return engine_type_of(.Spawn), true
	case "Despawn":
		return engine_type_of(.Despawn), true
	case "Draw":
		return engine_type_of(.Draw), true
	case "Rng":
		return engine_type_of(.Rng), true
	case "Input":
		return engine_type_of(.Input), true
	case "Bindings":
		return engine_type_of(.Bindings), true
	case "Time":
		return engine_type_of(.Time), true
	case "String":
		return engine_type_of(.String), true
	case "PlayerId":
		return engine_type_of(.PlayerId), true
	case "Key":
		return engine_type_of(.Key), true
	case "Stick":
		return engine_type_of(.Stick), true
	case "Color":
		return engine_type_of(.Color), true
	}
	return nil, false
}

// ground_type_name maps the bare type-name spellings the checker grounds to
// their Ground_Type. Vec2/Vec3 are engine records the evaluator already
// lowers (evaluate.odin), so they ground here too; the other engine types
// have no checker ground yet.
ground_type_name :: proc(name: string) -> (type: Type, found: bool) {
	switch name {
	case "Int":
		return Ground_Type.Int, true
	case "Fixed":
		return Ground_Type.Fixed, true
	case "Bool":
		return Ground_Type.Bool, true
	case "Vec2":
		return Ground_Type.Vec2, true
	case "Vec3":
		return Ground_Type.Vec3, true
	case "Quat":
		return Ground_Type.Quat, true
	}
	return nil, false
}

// env_type_name looks up a type-position user name (a record or enum) and
// returns its nominal handle. The name resolver (typecheck.odin) consults
// this after the let scope and the imports, so a user type is a bindable
// type-position name.
env_type_name :: proc(env: Type_Env, name: string) -> (type: Type, found: bool) {
	if record, is_record := env.records[name]; is_record {
		return user_type_of(record.type_name, record.kind), true
	}
	if _, is_enum := env.enums[name]; is_enum {
		return user_type_of(name, .Enum), true
	}
	return nil, false
}

// env_term_name looks up a value-position user name (a const, fn, or
// behavior). The name resolver uses found to decide a name binds; typing
// the term's use is the typing pass's job, so this only reports presence and
// the recorded schema.
env_term_name :: proc(env: Type_Env, name: string) -> (term: Term_Schema, found: bool) {
	term, found = env.terms[name]
	return
}

// env_declares reports whether any user declaration claims the name, across
// every partition — the single predicate the extended name resolver checks
// before falling through to Unresolved_Name.
env_declares :: proc(env: Type_Env, name: string) -> bool {
	if _, is_record := env.records[name]; is_record {
		return true
	}
	if _, is_enum := env.enums[name]; is_enum {
		return true
	}
	if _, is_term := env.terms[name]; is_term {
		return true
	}
	return false
}
