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
// against once it is registered (gates.odin). payloads carries each variant's
// single tuple-payload type in lockstep with variants (nil for a plain or
// multi-arg variant): the §21 §3 tagged-union router (AppMsg::Hud(HudMsg),
// SettingsMsg::SetVolume(Int)) types its variant payloads off this — a payload
// construction (AppMsg::Hud(m)) checks m against payloads[i], a match binder
// (AppMsg::Hud(m) => …) binds m to payloads[i], and the variant-as-function
// value (AppMsg::Hud per §21 §3) is fn(payloads[i]) -> the enum.
Enum_Schema :: struct {
	type_name: string,
	role:      string,
	variants:  []string,
	payloads:  []Type, // variant i's single tuple-payload type; nil when plain
}

// enum_variant_payload reads an enum variant's single tuple-payload type by
// variant name, returning has_payload = false for a plain variant or a name the
// enum does not declare. A linear walk over the source-ordered variant slice, so
// the verdict never depends on map order.
enum_variant_payload :: proc(schema: Enum_Schema, variant: string) -> (payload: Type, has_payload: bool) {
	for name, i in schema.variants {
		if name == variant {
			return schema.payloads[i], schema.payloads[i] != nil
		}
	}
	return nil, false
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
resolve_env :: proc(ast: Ast, bindings: Bindings, index: Module_Index = {}) -> (env: Type_Env, err: Type_Error) {
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
	// against the now-complete type namespace, the imports, and the
	// project-wide module index (a cross-module type name imported from a
	// sibling module), filling the recorded schemas.
	resolve_schemas(&env, ast, bindings, index)
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
		// The reservation runs BEFORE the collision claim so a reserved name
		// surfaces as the precise Reserved_Signal_Name diagnostic even when the
		// engine.physics import would also have raised the generic Name_Collision
		// — the same precision-first ordering the layer-registry gate uses.
		check_reserved_signal_name(decl.name) or_return
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
		// payloads is sized here and filled in pass 2 (resolve_enum_payloads),
		// once the whole type namespace is interned — a variant payload may name a
		// type declared later (AppMsg::Hud(HudMsg) where HudMsg follows AppMsg).
		env.enums[decl.name] = Enum_Schema {
			type_name = decl.name,
			role      = decl.kind,
			variants  = variants,
			payloads  = make([]Type, len(decl.variants), context.temp_allocator),
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

// ENGINE_ROUTED_SIGNALS is the closed set of signal names the runtime routes
// PER-INSTANCE rather than broadcast (spec §11 §4): its routing discriminates
// on these literal names, so a user signal declared as Trigger or Contact
// would silently read the empty per-instance list instead of the broadcast
// accumulator — even in a source that never imports engine.physics, where no
// Name_Collision fires. Reserving the names at declaration closes that one
// unenforced name dependency at compile time.
ENGINE_ROUTED_SIGNALS :: [2]string{"Trigger", "Contact"}

// check_reserved_signal_name rejects a user `signal` declaration whose name is
// engine-routed — the declaration-site gate the §11 §4 reservation rests on,
// enforced like the unregistered-layer registry rule.
check_reserved_signal_name :: proc(name: string) -> Type_Error {
	reserved := ENGINE_ROUTED_SIGNALS
	for routed in reserved {
		if name == routed {
			return .Reserved_Signal_Name
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
resolve_schemas :: proc(env: ^Type_Env, ast: Ast, bindings: Bindings, index: Module_Index = {}) {
	for decl in ast.things {
		schema := env.records[decl.name]
		schema.fields = resolve_field_schemas(env^, bindings, decl.fields, index)
		env.records[decl.name] = schema
	}
	for decl in ast.datas {
		schema := env.records[decl.name]
		schema.fields = resolve_field_schemas(env^, bindings, decl.fields, index)
		env.records[decl.name] = schema
	}
	for decl in ast.signals {
		schema := env.records[decl.name]
		schema.fields = resolve_field_schemas(env^, bindings, decl.fields, index)
		env.records[decl.name] = schema
	}
	for decl in ast.lets {
		term := env.terms[decl.name]
		term.type = resolve_type_ref(env^, bindings, decl.type, index)
		env.terms[decl.name] = term
	}
	for decl in ast.fns {
		term := env.terms[decl.name]
		term.signature = resolve_fn_signature(env^, bindings, decl.params, decl.return_type, index)
		env.terms[decl.name] = term
	}
	for decl in ast.behaviors {
		term := env.terms[decl.name]
		term.signature = resolve_fn_signature(env^, bindings, decl.step.params, decl.step.return_type, index)
		env.terms[decl.name] = term
	}
	resolve_enum_payloads(env, ast, bindings, index)
}

// resolve_enum_payloads fills each enum schema's variant payload types now that
// the whole type namespace is interned (spec §03 §2 tuple-payload variants). A
// single-arg tuple-payload variant (AppMsg::Hud(HudMsg), SettingsMsg::SetVolume(
// Int)) records its one payload type; a plain variant or a struct-payload variant
// leaves nil, and a multi-arg tuple payload (none on this surface) also leaves nil
// — the §21 §3 router carries exactly one payload per tagged variant. The payload
// ref resolves like any field ref, so a sibling-module type (a generated seam's
// HudMsg) resolves through the index too.
resolve_enum_payloads :: proc(env: ^Type_Env, ast: Ast, bindings: Bindings, index: Module_Index = {}) {
	for decl in ast.enums {
		schema := env.enums[decl.name]
		for variant, i in decl.variants {
			if variant.payload == .Tuple && len(variant.tuple) == 1 {
				schema.payloads[i] = resolve_type_ref(env^, bindings, variant.tuple[0], index)
			}
		}
		env.enums[decl.name] = schema
	}
}

// resolve_field_schemas resolves one record's field list into the recorded
// schema: each field keeps its name, has_default flag, and best-effort
// resolved type.
resolve_field_schemas :: proc(env: Type_Env, bindings: Bindings, fields: []Field_Decl, index: Module_Index = {}) -> []Field_Schema {
	out := make([]Field_Schema, len(fields), context.temp_allocator)
	for field, i in fields {
		out[i] = Field_Schema {
			name        = field.name,
			type        = resolve_type_ref(env, bindings, field.type, index),
			has_default = field.has_default,
		}
	}
	return out
}

// resolve_fn_signature builds a fn/step Func_Type from its parameter and
// return Type_Refs. The parameter types are the behavior's reads (spec §06
// §3); typing the body against them is the typing pass's job.
resolve_fn_signature :: proc(env: Type_Env, bindings: Bindings, params: []Param_Decl, return_type: Type_Ref, index: Module_Index = {}) -> ^Func_Type {
	param_types := make([]Type, len(params), context.temp_allocator)
	for param, i in params {
		param_types[i] = resolve_type_ref(env, bindings, param.type, index)
	}
	node := new(Func_Type, context.temp_allocator)
	node.params = param_types
	node.result = resolve_type_ref(env, bindings, return_type, index)
	return node
}

// resolve_type_ref maps a syntactic Type_Ref (parser.odin) to the checker's
// semantic Type, consulting the ground types, the user environment, the
// engine ground records (Vec2/Vec3), and the parameterized Option/List
// heads. A name that resolves to nothing concrete yet — an imported engine
// type with no checker ground (View, Input, Spawn), or a generic over one —
// returns nil: the resolver records the schema slot without forcing a type
// the typing pass owns.
resolve_type_ref :: proc(env: Type_Env, bindings: Bindings, ref: Type_Ref, index: Module_Index = {}) -> Type {
	// A list type `[T]` is the head "[]" with one element argument.
	if ref.name == "[]" {
		if len(ref.args) == 1 {
			return list_of(resolve_type_ref(env, bindings, ref.args[0], index))
		}
		return nil
	}
	// A tuple type `(T, U, …)` is the head "()" with its positional element
	// types as args (spec §04 §1: the `(value, next_rng)` return pair). Each
	// position resolves like any other ref; the tuple node carries them in order.
	if ref.name == "()" {
		elements := make([]Type, len(ref.args), context.temp_allocator)
		for arg, i in ref.args {
			elements[i] = resolve_type_ref(env, bindings, arg, index)
		}
		return tuple_of(elements)
	}
	if ref.name == "Option" && len(ref.args) == 1 {
		return option_of(resolve_type_ref(env, bindings, ref.args[0], index))
	}
	// View[T] is the §08 read table over an element type; the element
	// resolves like any other ref (a user thing for View[Paddle]).
	if ref.name == "View" && len(ref.args) == 1 {
		return engine_type_of(.View, resolve_type_ref(env, bindings, ref.args[0], index))
	}
	// Ref[T] is the §08 typed reference the §17 level bake resolves names to
	// (Ref[Player], a Door.gate); like View it is only ever parameterized, so
	// its element resolves like any other ref and it carries no bare-name arm.
	if ref.name == "Ref" && len(ref.args) == 1 {
		return engine_type_of(.Ref, resolve_type_ref(env, bindings, ref.args[0]))
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
		// A name imported from a sibling user module (a `gate: Ref[Switch]`
		// where Switch came from arena_world, a `hero: Ref[Player]` in a seam):
		// resolve it to the same nominal User_Type the owning module would,
		// recovering its §06 kind from the module index. This runs after the
		// local env so a local declaration of the same name wins (a §02
		// collision would have already rejected a local decl shadowing the
		// import).
		if cross, is_cross := index_user_type(index, bindings, ref.name); is_cross {
			return cross
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
	// §11 physics: a `body: Body` field, a `shape: Shape2` field, a `kind:
	// BodyKind` field, and a `pads: [Trigger]` inbound signal all name an
	// engine type here. Box/Circle and Static/Dynamic/Kinematic are reached
	// through the enum's variant surface, not as bare type-refs.
	case "Body":
		return engine_type_of(.Body), true
	case "BodyKind":
		return engine_type_of(.BodyKind), true
	case "Shape2":
		return engine_type_of(.Shape2), true
	case "Trigger":
		return engine_type_of(.Trigger), true
	// §24 persistence: a `settings: Settings` field and the inbound result
	// signals (`saved: [Saved]`, `restored: [Restored]`, `applied:
	// [SettingsApplied]`) name engine types in field/param position; the
	// Save/Restore/ApplySettings command types name the element of a persist
	// behavior's emitted command list (`-> [Save]`, `-> [Restore]`,
	// `-> [ApplySettings]`), so they ground here like Spawn/Despawn/Draw.
	case "Save":
		return engine_type_of(.Save), true
	case "Restore":
		return engine_type_of(.Restore), true
	case "ApplySettings":
		return engine_type_of(.ApplySettings), true
	case "Settings":
		return engine_type_of(.Settings), true
	case "AccessOpts":
		return engine_type_of(.AccessOpts), true
	case "Saved":
		return engine_type_of(.Saved), true
	case "Restored":
		return engine_type_of(.Restored), true
	case "SettingsApplied":
		return engine_type_of(.SettingsApplied), true
	// §08 nav: a `nav: Nav` query handle, a `route: Path` field, and a
	// NavError query-failure variant all name an engine type in field/param
	// position. Ref is parameterized (Ref[T]) and grounds in the Ref[T] arm of
	// resolve_type_ref, mirroring View — it is omitted here.
	case "Nav":
		return engine_type_of(.Nav), true
	case "Path":
		return engine_type_of(.Path), true
	case "NavError":
		return engine_type_of(.NavError), true
	// §19/§26 the typed asset handles name an engine type in a seam constant's
	// `let NAME: KINDHandle` declaration and a behavior's `atlas: AtlasHandle`
	// field; they ground here like Spawn/Draw. Their construction schema (the
	// single String `name` field) is surface_engine_record.
	case "MeshHandle":
		return engine_type_of(.MeshHandle), true
	case "TextureHandle":
		return engine_type_of(.TextureHandle), true
	case "SoundHandle":
		return engine_type_of(.SoundHandle), true
	case "AtlasHandle":
		return engine_type_of(.AtlasHandle), true
	// §16 §7 anim: a pose generator's `-> Pose` return, a rig seam's `-> Skeleton`/
	// `-> PartSet` returns, and a `transform: Transform` slot all name an engine
	// type in field/param/return position. Slot/Side/Bone ground here too so a
	// bare `kind: Bone` field would resolve; their variant values are reached
	// through surface_enum_variant.
	case "Skeleton":
		return engine_type_of(.Skeleton), true
	case "PartSet":
		return engine_type_of(.PartSet), true
	case "Slot":
		return engine_type_of(.Slot), true
	case "Side":
		return engine_type_of(.Side), true
	case "Pose":
		return engine_type_of(.Pose), true
	case "Bone":
		return engine_type_of(.Bone), true
	case "Transform":
		return engine_type_of(.Transform), true
	// §20 §1 render3: Draw3 names the element of a render3 behavior's `-> [Draw3]`
	// return; Material a `mat: Material` field. Both ground here like Draw/Spawn.
	case "Draw3":
		return engine_type_of(.Draw3), true
	case "Material":
		return engine_type_of(.Material), true
	// §22 audio: a `-> [Sound]` one-shot command list, a `-> [Audio]` sustained
	// projection list, and a `bus: Bus` field all name an engine type in
	// field/param/return position; the Sound/Audio builders' chained results
	// ground here too. Master/Music/Sfx/Ui/Voice are reached through Bus's variant
	// surface (surface_enum_variant), not as bare type-refs.
	case "Sound":
		return engine_type_of(.Sound), true
	case "Audio":
		return engine_type_of(.Audio), true
	case "Bus":
		return engine_type_of(.Bus), true
	// §21 ui: a `-> View[Msg]` projection grounds through the View[T] arm above;
	// UiAction and Theme name engine types in field/param position.
	case "UiAction":
		return engine_type_of(.UiAction), true
	case "Theme":
		return engine_type_of(.Theme), true
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
