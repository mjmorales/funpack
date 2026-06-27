package funpack

Record_Schema :: struct {
	type_name: string,
	kind:      User_Kind,
	fields:    []Field_Schema,
}

Field_Schema :: struct {
	name:        string,
	type:        Type,
	has_default: bool,
}

Enum_Schema :: struct {
	type_name: string,
	role:      string,
	variants:  []string,
	payloads:  []Type,
}

enum_variant_payload :: proc(schema: Enum_Schema, variant: string) -> (payload: Type, has_payload: bool) {
	for name, i in schema.variants {
		if name == variant {
			return schema.payloads[i], schema.payloads[i] != nil
		}
	}
	return nil, false
}

Term_Schema :: struct {
	name:      string,
	kind:      Term_Kind,
	type:      Type,
	signature: ^Func_Type,
	target:    string,
}

Term_Kind :: enum {
	Const,
	Fn,
	Query,
	Behavior,
}

Type_Env :: struct {
	records: map[string]Record_Schema,
	enums:   map[string]Enum_Schema,
	terms:   map[string]Term_Schema,
}

resolve_env :: proc(ast: Ast, bindings: Bindings, index: Module_Index = {}, site: ^Type_Diag_Site = nil) -> (env: Type_Env, err: Type_Error) {
	env.records = make(map[string]Record_Schema, context.temp_allocator)
	env.enums = make(map[string]Enum_Schema, context.temp_allocator)
	env.terms = make(map[string]Term_Schema, context.temp_allocator)

	collect_type_names(&env, ast, bindings, site) or_return
	collect_term_names(&env, ast, bindings, site) or_return

	resolve_schemas(&env, ast, bindings, index)
	return env, .None
}

collect_type_names :: proc(env: ^Type_Env, ast: Ast, bindings: Bindings, site: ^Type_Diag_Site = nil) -> Type_Error {
	for decl in ast.things {
		if err := claim_type_name(env, decl.name, bindings); err != .None {
			stamp_decl(site, decl.name, decl.line)
			return err
		}
		env.records[decl.name] = Record_Schema {
			type_name = decl.name,
			kind      = .Thing,
		}
	}
	for decl in ast.datas {
		if err := claim_type_name(env, decl.name, bindings); err != .None {
			stamp_decl(site, decl.name, decl.line)
			return err
		}
		env.records[decl.name] = Record_Schema {
			type_name = decl.name,
			kind      = .Data,
		}
	}
	for decl in ast.signals {
		if err := check_reserved_signal_name(decl.name); err != .None {
			stamp_decl(site, decl.name, decl.line)
			return err
		}
		if err := claim_type_name(env, decl.name, bindings); err != .None {
			stamp_decl(site, decl.name, decl.line)
			return err
		}
		env.records[decl.name] = Record_Schema {
			type_name = decl.name,
			kind      = .Signal,
		}
	}
	for decl in ast.enums {
		if err := claim_type_name(env, decl.name, bindings); err != .None {
			stamp_decl(site, decl.name, decl.line)
			return err
		}
		variants := make([]string, len(decl.variants), context.temp_allocator)
		for variant, i in decl.variants {
			variants[i] = variant.name
		}
		env.enums[decl.name] = Enum_Schema {
			type_name = decl.name,
			role      = decl.kind,
			variants  = variants,
			payloads  = make([]Type, len(decl.variants), context.temp_allocator),
		}
	}
	return .None
}

collect_term_names :: proc(env: ^Type_Env, ast: Ast, bindings: Bindings, site: ^Type_Diag_Site = nil) -> Type_Error {
	for decl in ast.lets {
		if err := claim_term_name(env, decl.name, bindings); err != .None {
			stamp_decl(site, decl.name, decl.line)
			return err
		}
		env.terms[decl.name] = Term_Schema{name = decl.name, kind = .Const}
	}
	for decl in ast.fns {
		if err := claim_term_name(env, decl.name, bindings); err != .None {
			stamp_decl(site, decl.name, decl.line)
			return err
		}
		env.terms[decl.name] = Term_Schema{name = decl.name, kind = .Fn}
	}
	for decl in ast.queries {
		if err := claim_term_name(env, decl.name, bindings); err != .None {
			stamp_decl(site, decl.name, decl.line)
			return err
		}
		env.terms[decl.name] = Term_Schema{name = decl.name, kind = .Query}
	}
	for decl in ast.behaviors {
		if err := claim_term_name(env, decl.name, bindings); err != .None {
			stamp_decl(site, decl.name, decl.line)
			return err
		}
		env.terms[decl.name] = Term_Schema {
			name   = decl.name,
			kind   = .Behavior,
			target = decl.target,
		}
	}
	return .None
}

ENGINE_ROUTED_SIGNALS :: [2]string{"Trigger", "Contact"}

check_reserved_signal_name :: proc(name: string) -> Type_Error {
	reserved := ENGINE_ROUTED_SIGNALS
	for routed in reserved {
		if name == routed {
			return .Reserved_Signal_Name
		}
	}
	return .None
}

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
	for decl in ast.queries {
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

resolve_type_ref :: proc(env: Type_Env, bindings: Bindings, ref: Type_Ref, index: Module_Index = {}) -> Type {
	if ref.name == "[]" {
		if len(ref.args) == 1 {
			return list_of(resolve_type_ref(env, bindings, ref.args[0], index))
		}
		return nil
	}
	if ref.name == "fn" {
		if len(ref.args) == 0 {
			return nil
		}
		param_count := len(ref.args) - 1
		params := make([]Type, param_count, context.temp_allocator)
		for arg, i in ref.args[:param_count] {
			params[i] = resolve_type_ref(env, bindings, arg, index)
		}
		return func_of(params, resolve_type_ref(env, bindings, ref.args[param_count], index))
	}
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
	if ref.name == "Map" && len(ref.args) == 2 {
		return map_of(
			resolve_type_ref(env, bindings, ref.args[0], index),
			resolve_type_ref(env, bindings, ref.args[1], index),
		)
	}
	if ref.name == "View" && len(ref.args) == 1 {
		return engine_type_of(.View, resolve_type_ref(env, bindings, ref.args[0], index))
	}
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
		if record, is_structural := surface_structural_record(bindings, ref.name); is_structural {
			return user_type_of(record.type_name, record.kind)
		}
		if cross, is_cross := index_user_type(index, bindings, ref.name); is_cross {
			return cross
		}
	}
	return nil
}

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
	case "PadButton":
		return engine_type_of(.PadButton), true
	case "MouseButton":
		return engine_type_of(.MouseButton), true
	case "Stick":
		return engine_type_of(.Stick), true
	case "Color":
		return engine_type_of(.Color), true
	case "Ordering":
		return engine_type_of(.Ordering), true
	case "Flip":
		return engine_type_of(.Flip), true
	case "Align":
		return engine_type_of(.Align), true
	case "Body":
		return engine_type_of(.Body), true
	case "BodyKind":
		return engine_type_of(.BodyKind), true
	case "Shape2":
		return engine_type_of(.Shape2), true
	case "Trigger":
		return engine_type_of(.Trigger), true
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
	case "Nav":
		return engine_type_of(.Nav), true
	case "Path":
		return engine_type_of(.Path), true
	case "NavError":
		return engine_type_of(.NavError), true
	case "MeshHandle":
		return engine_type_of(.MeshHandle), true
	case "TextureHandle":
		return engine_type_of(.TextureHandle), true
	case "SoundHandle":
		return engine_type_of(.SoundHandle), true
	case "AtlasHandle":
		return engine_type_of(.AtlasHandle), true
	case "TilesetHandle":
		return engine_type_of(.TilesetHandle), true
	case "TilemapHandle":
		return engine_type_of(.TilemapHandle), true
	case "SetTile":
		return engine_type_of(.SetTile), true
	case "BuildLayer":
		return engine_type_of(.BuildLayer), true
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
	case "Draw3":
		return engine_type_of(.Draw3), true
	case "Material":
		return engine_type_of(.Material), true
	case "Sound":
		return engine_type_of(.Sound), true
	case "Audio":
		return engine_type_of(.Audio), true
	case "Bus":
		return engine_type_of(.Bus), true
	case "UiAction":
		return engine_type_of(.UiAction), true
	case "Theme":
		return engine_type_of(.Theme), true
	}
	return nil, false
}

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

env_type_name :: proc(env: Type_Env, name: string) -> (type: Type, found: bool) {
	if record, is_record := env.records[name]; is_record {
		return user_type_of(record.type_name, record.kind), true
	}
	if _, is_enum := env.enums[name]; is_enum {
		return user_type_of(name, .Enum), true
	}
	return nil, false
}

env_term_name :: proc(env: Type_Env, name: string) -> (term: Term_Schema, found: bool) {
	term, found = env.terms[name]
	return
}

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
