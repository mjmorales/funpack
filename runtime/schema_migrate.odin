package funpack_runtime

import "core:strings"

Old_Schema :: struct {
	name:   string,
	fields: []Schema_Field,
}

Schema_Set :: struct {
	data:   []Old_Schema,
	things: []Old_Schema,
}

Migrate_Refusal_Kind :: enum {
	None,
	Kernel,
	Thing_Set_Delta,
	Missing_Column,
	Convert_Failed,
	Default_Undecodable,
}

Migrate_Refusal :: struct {
	kind:     Migrate_Refusal_Kind,
	scope:    string,
	offender: string,
	verdict:  Schema_Diff_Error,
}

Migration_Set :: struct {
	thing_plans:  map[string][]Migration_Action,
	data_plans:   map[string][]Migration_Action,
	type_renames: map[string]string,
}

program_schemas :: proc(program: ^Program, allocator := context.allocator) -> Schema_Set {
	data := make([]Old_Schema, len(program.data), allocator)
	for decl, i in program.data {
		data[i] = Old_Schema{name = decl.name, fields = schema_fields_of(decl.fields, allocator)}
	}
	things := make([]Old_Schema, len(program.things), allocator)
	for decl, i in program.things {
		things[i] = Old_Schema{name = decl.name, fields = schema_fields_of(decl.fields, allocator)}
	}
	return Schema_Set{data = data, things = things}
}

schema_fields_of :: proc(fields: []Field_Decl, allocator := context.allocator) -> []Schema_Field {
	out := make([]Schema_Field, len(fields), allocator)
	for fd, i in fields {
		out[i] = Schema_Field {
			name          = fd.name,
			type_spelling = fd.type,
			default_token = fd.default_encoded,
			has_default   = fd.has_default,
			migrate_from  = fd.migrate_from,
			has_from      = fd.has_from,
			migrate_with  = fd.migrate_with,
			has_with      = fd.has_with,
		}
	}
	return out
}

compile_migration :: proc(
	old: Schema_Set,
	program: ^Program,
	allocator := context.allocator,
) -> (
	set: Migration_Set,
	refusal: Migrate_Refusal,
) {
	set.type_renames = make(map[string]string, allocator)
	for decl in program.data {
		if decl.has_prior {
			set.type_renames[decl.prior_name] = decl.name
		}
	}

	set.data_plans = make(map[string][]Migration_Action, allocator)
	for &decl in program.data {
		old_name := decl.has_prior ? decl.prior_name : decl.name
		old_schema, found := find_old_schema(old.data, old_name)
		if !found {
			continue
		}
		canon := rename_schema_spellings(old_schema.fields, set.type_renames, allocator)
		plan, offender, err := diff_schemas(canon, schema_fields_of(decl.fields, allocator), allocator)
		if err != .None {
			return set, Migrate_Refusal{kind = .Kernel, scope = decl.name, offender = offender, verdict = err}
		}
		set.data_plans[decl.name] = plan
	}

	if len(old.things) != len(program.things) {
		return set, Migrate_Refusal{kind = .Thing_Set_Delta}
	}
	set.thing_plans = make(map[string][]Migration_Action, allocator)
	for &decl in program.things {
		old_schema, found := find_old_schema(old.things, decl.name)
		if !found {
			return set, Migrate_Refusal{kind = .Thing_Set_Delta, scope = decl.name}
		}
		canon := rename_schema_spellings(old_schema.fields, set.type_renames, allocator)
		plan, offender, err := diff_schemas(canon, schema_fields_of(decl.fields, allocator), allocator)
		if err != .None {
			return set, Migrate_Refusal{kind = .Kernel, scope = decl.name, offender = offender, verdict = err}
		}
		set.thing_plans[decl.name] = plan
	}
	return set, Migrate_Refusal{}
}

find_old_schema :: proc(schemas: []Old_Schema, name: string) -> (schema: Old_Schema, found: bool) {
	for candidate in schemas {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Old_Schema{}, false
}

rename_schema_spellings :: proc(
	fields: []Schema_Field,
	renames: map[string]string,
	allocator := context.allocator,
) -> []Schema_Field {
	if len(renames) == 0 {
		return fields
	}
	out := make([]Schema_Field, len(fields), allocator)
	for fd, i in fields {
		out[i] = fd
		out[i].type_spelling = rename_spelling(fd.type_spelling, renames, allocator)
	}
	return out
}

rename_spelling :: proc(spelling: string, renames: map[string]string, allocator := context.allocator) -> string {
	if to, hit := renames[spelling]; hit {
		return to
	}
	open := strings.index_byte(spelling, '[')
	if open >= 0 && strings.has_suffix(spelling, "]") {
		ctor := spelling[:open]
		if to, hit := renames[ctor]; hit {
			ctor = to
		}
		inner := rename_spelling(spelling[open + 1:len(spelling) - 1], renames, allocator)
		return strings.concatenate({ctor, "[", inner, "]"}, allocator)
	}
	return spelling
}

migrate_world_version :: proc(
	set: Migration_Set,
	world: World_Version,
	program: ^Program,
	carry: Tile_Carry_Delta,
	allocator := context.allocator,
) -> (
	migrated: World_Version,
	refusal: Migrate_Refusal,
) {
	empty_version := World_Version{}
	interp := new_interp(program, &empty_version, nil, empty(), migrate_time_resource(allocator), allocator)

	tables := make([]Version_Table, len(world.tables), allocator)
	for table, ti in world.tables {
		decl := program_thing(program, table.thing)
		if decl == nil {
			return {}, Migrate_Refusal{kind = .Thing_Set_Delta, scope = table.thing}
		}
		if decl.singleton != table.singleton {
			return {}, Migrate_Refusal{kind = .Thing_Set_Delta, scope = table.thing}
		}
		plan := set.thing_plans[table.thing]
		rows := make([]Row, len(table.rows), allocator)
		for row, ri in table.rows {
			fields := make(map[string]Field_Value, len(plan), allocator)
			for action in plan {
				value, field_refusal := migrate_row_field(set, program, &interp, decl, row, action, allocator)
				if field_refusal.kind != .None {
					return {}, field_refusal
				}
				fields[strings.clone(action.field, allocator)] = value
			}
			rows[ri] = Row{id = row.id, fields = fields}
		}
		tables[ti] = Version_Table {
			thing     = strings.clone(table.thing, allocator),
			singleton = table.singleton,
			rows      = rows,
			next_id   = table.next_id,
		}
	}
	carried := tile_carry_apply(carry, program.tilemaps, allocator)
	return World_Version{tick = world.tick, tables = tables, tilemaps = carried}, Migrate_Refusal{}
}

migrate_row_field :: proc(
	set: Migration_Set,
	program: ^Program,
	interp: ^Interp,
	decl: ^Thing_Decl,
	row: Row,
	action: Migration_Action,
	allocator := context.allocator,
) -> (
	value: Field_Value,
	refusal: Migrate_Refusal,
) {
	switch action.op {
	case .Carry, .Rename:
		old_value, present := row.fields[action.source]
		if !present {
			return nil, Migrate_Refusal{kind = .Missing_Column, scope = decl.name, offender = action.source}
		}
		return migrate_column(set, program, interp, old_value, allocator)
	case .Convert:
		old_value, present := row.fields[action.source]
		if !present {
			return nil, Migrate_Refusal{kind = .Missing_Column, scope = decl.name, offender = action.source}
		}
		converted, ok := run_conversion(interp, action.convert, field_value_to_value(old_value))
		if !ok {
			return nil, Migrate_Refusal{kind = .Convert_Failed, scope = decl.name, offender = action.field}
		}
		lowered, lower_ok := value_to_field_value(converted, allocator)
		if !lower_ok {
			return nil, Migrate_Refusal{kind = .Convert_Failed, scope = decl.name, offender = action.field}
		}
		return lowered, Migrate_Refusal{}
	case .Default:
		fd, found := thing_field_decl(decl, action.field)
		if !found {
			return nil, Migrate_Refusal{kind = .Default_Undecodable, scope = decl.name, offender = action.field}
		}
		decoded, ok := decode_default(program, fd, allocator)
		if !ok {
			return nil, Migrate_Refusal{kind = .Default_Undecodable, scope = decl.name, offender = action.field}
		}
		return decoded, Migrate_Refusal{}
	}
	return nil, Migrate_Refusal{kind = .Convert_Failed, scope = decl.name, offender = action.field}
}

migrate_column :: proc(
	set: Migration_Set,
	program: ^Program,
	interp: ^Interp,
	value: Field_Value,
	allocator := context.allocator,
) -> (
	migrated: Field_Value,
	refusal: Migrate_Refusal,
) {
	switch v in value {
	case Record_Value:
		rec, rec_refusal := migrate_record(set, program, interp, v, allocator)
		if rec_refusal.kind != .None {
			return nil, rec_refusal
		}
		return rec, Migrate_Refusal{}
	case List_Value:
		list, list_refusal := migrate_list(set, program, interp, v, allocator)
		if list_refusal.kind != .None {
			return nil, list_refusal
		}
		return list, Migrate_Refusal{}
	case Map_Value:
		m, map_refusal := migrate_map(set, program, interp, v, allocator)
		if map_refusal.kind != .None {
			return nil, map_refusal
		}
		return m, Migrate_Refusal{}
	case Variant_Value:
		variant, var_refusal := migrate_variant(set, program, interp, v, allocator)
		if var_refusal.kind != .None {
			return nil, var_refusal
		}
		return variant, Migrate_Refusal{}
	case i64, Fixed, bool, string, Vec2, Vec3, Ref, String_Value:
		return value, Migrate_Refusal{}
	}
	return value, Migrate_Refusal{}
}

migrate_value :: proc(
	set: Migration_Set,
	program: ^Program,
	interp: ^Interp,
	value: Value,
	allocator := context.allocator,
) -> (
	migrated: Value,
	refusal: Migrate_Refusal,
) {
	#partial switch v in value {
	case Record_Value:
		return migrate_record(set, program, interp, v, allocator)
	case List_Value:
		rec, list_refusal := migrate_list(set, program, interp, v, allocator)
		return rec, list_refusal
	case Map_Value:
		m, map_refusal := migrate_map(set, program, interp, v, allocator)
		return m, map_refusal
	case Variant_Value:
		return migrate_variant(set, program, interp, v, allocator)
	}
	return value, Migrate_Refusal{}
}

migrate_map :: proc(
	set: Migration_Set,
	program: ^Program,
	interp: ^Interp,
	m: Map_Value,
	allocator := context.allocator,
) -> (
	migrated: Map_Value,
	refusal: Migrate_Refusal,
) {
	entries := make([]Map_Entry, len(m.entries), allocator)
	for entry, i in m.entries {
		key, key_refusal := migrate_value(set, program, interp, entry.key, allocator)
		if key_refusal.kind != .None {
			return {}, key_refusal
		}
		value, value_refusal := migrate_value(set, program, interp, entry.value, allocator)
		if value_refusal.kind != .None {
			return {}, value_refusal
		}
		entries[i] = Map_Entry{key = key, value = value}
	}
	return Map_Value{entries = entries}, Migrate_Refusal{}
}

migrate_record :: proc(
	set: Migration_Set,
	program: ^Program,
	interp: ^Interp,
	rec: Record_Value,
	allocator := context.allocator,
) -> (
	migrated: Record_Value,
	refusal: Migrate_Refusal,
) {
	new_name := rec.type_name
	if to, hit := set.type_renames[rec.type_name]; hit {
		new_name = to
	}
	plan, has_plan := set.data_plans[new_name]
	if !has_plan {
		out := rec
		out.type_name = strings.clone(new_name, allocator)
		return out, Migrate_Refusal{}
	}
	decl := program_data(program, new_name)
	fields := make(map[string]Value, len(plan), allocator)
	for action in plan {
		switch action.op {
		case .Carry, .Rename:
			old_value, present := rec.fields[action.source]
			if !present {
				return {}, Migrate_Refusal{kind = .Missing_Column, scope = new_name, offender = action.source}
			}
			value, deep_refusal := migrate_value(set, program, interp, old_value, allocator)
			if deep_refusal.kind != .None {
				return {}, deep_refusal
			}
			fields[strings.clone(action.field, allocator)] = value
		case .Convert:
			old_value, present := rec.fields[action.source]
			if !present {
				return {}, Migrate_Refusal{kind = .Missing_Column, scope = new_name, offender = action.source}
			}
			converted, ok := run_conversion(interp, action.convert, old_value)
			if !ok {
				return {}, Migrate_Refusal{kind = .Convert_Failed, scope = new_name, offender = action.field}
			}
			fields[strings.clone(action.field, allocator)] = converted
		case .Default:
			field_type := data_field_type(decl, action.field)
			token := strings.trim_prefix(action.default_token, "=")
			decoded, ok := decode_default_to_value(program, field_type, token, allocator)
			if !ok {
				return {}, Migrate_Refusal{kind = .Default_Undecodable, scope = new_name, offender = action.field}
			}
			fields[strings.clone(action.field, allocator)] = decoded
		}
	}
	return Record_Value{type_name = strings.clone(new_name, allocator), fields = fields}, Migrate_Refusal{}
}

migrate_list :: proc(
	set: Migration_Set,
	program: ^Program,
	interp: ^Interp,
	list: List_Value,
	allocator := context.allocator,
) -> (
	migrated: List_Value,
	refusal: Migrate_Refusal,
) {
	elements := make([]Value, len(list.elements), allocator)
	for elem, i in list.elements {
		value, elem_refusal := migrate_value(set, program, interp, elem, allocator)
		if elem_refusal.kind != .None {
			return {}, elem_refusal
		}
		elements[i] = value
	}
	return List_Value{elements = elements}, Migrate_Refusal{}
}

migrate_variant :: proc(
	set: Migration_Set,
	program: ^Program,
	interp: ^Interp,
	variant: Variant_Value,
	allocator := context.allocator,
) -> (
	migrated: Variant_Value,
	refusal: Migrate_Refusal,
) {
	if variant.payload == nil {
		return variant, Migrate_Refusal{}
	}
	inner, inner_refusal := migrate_value(set, program, interp, variant.payload^, allocator)
	if inner_refusal.kind != .None {
		return {}, inner_refusal
	}
	payload := new(Value, allocator)
	payload^ = inner
	out := variant
	out.payload = payload
	return out, Migrate_Refusal{}
}

run_conversion :: proc(interp: ^Interp, name: string, arg: Value) -> (value: Value, ok: bool) {
	fn := program_function(interp.program, name)
	if fn == nil || len(fn.params) != 1 {
		return nil, false
	}
	scope := Env{names = make(map[string]Value, interp.allocator)}
	scope.names[fn.params[0].name] = arg
	return eval_body(interp, fn.body, &scope)
}

thing_field_decl :: proc(decl: ^Thing_Decl, name: string) -> (fd: Field_Decl, found: bool) {
	for candidate in decl.fields {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Field_Decl{}, false
}

migrate_time_resource :: proc(allocator := context.allocator) -> Record_Value {
	return Record_Value{type_name = "Time", fields = make(map[string]Value, allocator)}
}
