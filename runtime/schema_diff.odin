package funpack_runtime

Schema_Field :: struct {
	name:          string,
	type_spelling: string,
	default_token: string,
	has_default:   bool,
	migrate_from:  string,
	has_from:      bool,
	migrate_with:  string,
	has_with:      bool,
}

Migration_Op :: enum {
	Carry,
	Rename,
	Convert,
	Default,
}

Migration_Action :: struct {
	field:         string,
	op:            Migration_Op,
	source:        string,
	convert:       string,
	default_token: string,
}

Schema_Diff_Error :: enum {
	None,
	Duplicate_Field,
	Unknown_Source,
	Retype_Without_Migrate,
	Rename_Type_Changed,
	Missing_Default,
}

diff_schemas :: proc(
	old_schema: []Schema_Field,
	new_schema: []Schema_Field,
	allocator := context.allocator,
) -> (
	plan: []Migration_Action,
	offender: string,
	err: Schema_Diff_Error,
) {
	if dup, found := first_duplicate_name(old_schema); found {
		return nil, dup, .Duplicate_Field
	}
	if dup, found := first_duplicate_name(new_schema); found {
		return nil, dup, .Duplicate_Field
	}
	actions := make([dynamic]Migration_Action, 0, len(new_schema), allocator)
	for field in new_schema {
		action, field_err := classify_field(old_schema, field)
		if field_err != .None {
			delete(actions)
			return nil, field.name, field_err
		}
		append(&actions, action)
	}
	return actions[:], "", .None
}

classify_field :: proc(old_schema: []Schema_Field, field: Schema_Field) -> (action: Migration_Action, err: Schema_Diff_Error) {
	if field.has_from || field.has_with {
		source_key := field.migrate_from if field.has_from else field.name
		source, found := find_field(old_schema, source_key)
		if !found {
			return action, .Unknown_Source
		}
		if field.has_with {
			return Migration_Action{field = field.name, op = .Convert, source = source_key, convert = field.migrate_with}, .None
		}
		if source.type_spelling != field.type_spelling {
			return action, .Rename_Type_Changed
		}
		return Migration_Action{field = field.name, op = .Rename, source = source_key}, .None
	}
	if source, found := find_field(old_schema, field.name); found {
		if source.type_spelling != field.type_spelling {
			return action, .Retype_Without_Migrate
		}
		return Migration_Action{field = field.name, op = .Carry, source = field.name}, .None
	}
	if !field.has_default {
		return action, .Missing_Default
	}
	return Migration_Action{field = field.name, op = .Default, default_token = field.default_token}, .None
}

find_field :: proc(schema: []Schema_Field, name: string) -> (field: Schema_Field, found: bool) {
	for candidate in schema {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Schema_Field{}, false
}

first_duplicate_name :: proc(schema: []Schema_Field) -> (name: string, found: bool) {
	for field, i in schema {
		for earlier in schema[:i] {
			if earlier.name == field.name {
				return field.name, true
			}
		}
	}
	return "", false
}
