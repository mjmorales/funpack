// The schema-migration EXECUTOR (spec §09 §4, §24 §1): fold the schema-diff
// kernel's plan (schema_diff.odin, this runtime's own kernel copy) over a
// committed World_Version, producing the world the NEW schema declares. It is
// the ONE mechanism §09 §4 mandates be shared between the two consumers:
//
//   - RESTORE under a changed schema (§24): the old schemas ride the snapshot
//     (save_io.odin codec v5), the new ones are the loaded artifact's decls;
//   - HOT-RELOAD at the tick boundary (§09 §3): the old schemas are the running
//     program's decls, the new ones the recompiled artifact's.
//
// The split of labor mirrors the kernel's contract: the kernel COMPILES the
// per-field plan (Carry/Rename/Convert/Default, refusing the five named
// classes); this executor RUNS it — by-name copies for Carry/Rename, the §05 §6
// conversion fn through the interpreter for Convert (an ordinary [functions]
// record resolved by bare name), and the declared default token through the
// loader's default decoder for Default. Every refusal is a VALUE
// (Migrate_Refusal), never a partial world: the caller keeps the old world and
// surfaces the verdict (a Restore yields Result::Err, a reload keeps the
// last-good artifact running — the §09 §3 non-destructive failure).
//
// SETTLED-SPEC BOUNDARY (deliberately narrow). §09 §4's verdict table settles
// FIELD-level deltas on name-keyed schemas — nothing else. A decl-SET delta
// (a thing added or removed between the old and new worlds, or a singleton
// flip) is NOT settled by the table, so it REFUSES fail-closed
// (Thing_Set_Delta) rather than inventing semantics; the §27 mod
// load-with-discard arm is a modding-layer concern this runtime does not carry
// yet. Enum reshapes have no @migrate channel at all (§05 §6 admits the
// directive on `data` only), so variant tokens carry verbatim.
package funpack_runtime

import "core:strings"

// Old_Schema is one name-keyed schema as the OLD world declared it — the only
// two facts the kernel reads from the old side (classify_field consults old
// fields by name and type spelling alone; defaults and migrate metadata are
// new-side facts). Built from a v5 snapshot's schema carry (restore) or from
// the running program's decls (hot-reload).
Old_Schema :: struct {
	name:   string,
	fields: []Schema_Field, // only name/type_spelling are meaningful on the old side
}

// Schema_Set is the old world's full schema inventory: its data decls and its
// thing blackboard schemas, in declaration order.
Schema_Set :: struct {
	data:   []Old_Schema,
	things: []Old_Schema,
}

// Migrate_Refusal_Kind is the closed refusal vocabulary of the executor — the
// kernel's verdicts plus the executor's own fail-closed arms, one named kind
// per repair.
Migrate_Refusal_Kind :: enum {
	None,
	Kernel, // the schema-diff kernel refused: `verdict` + `offender` name the class and field
	Thing_Set_Delta, // the old and new worlds declare different thing sets (or a singleton flip) — §09 §4 settles field deltas only, so a decl-set delta fails closed
	Missing_Column, // a row lacks a column its recorded schema declares — a corrupt snapshot, refused before any partial fold
	Convert_Failed, // the §05 §6 conversion fn is absent, not arity-1, or its body failed to evaluate
	Default_Undecodable, // an additive field's declared default token did not decode against its type
}

// Migrate_Refusal is the migration failure as a VALUE: the kind, the decl it
// arose on (a thing or data name), the field the verdict names, and — for the
// Kernel kind — the kernel's own named class. kind == .None is success.
Migrate_Refusal :: struct {
	kind:     Migrate_Refusal_Kind,
	scope:    string, // the thing/data decl the refusal is about
	offender: string, // the field (or prior key) the verdict names
	verdict:  Schema_Diff_Error, // the kernel's class (Kernel kind only; .None otherwise)
}

// Migration_Set is the compiled whole-world plan: one kernel plan per thing
// blackboard, one per surviving data type (keyed by the NEW type name), and
// the old→new TYPE-name map decl-level renames declare. Compiled once per
// restore/reload, then folded over every row.
Migration_Set :: struct {
	thing_plans:  map[string][]Migration_Action,
	data_plans:   map[string][]Migration_Action,
	type_renames: map[string]string, // old data type name → new (decl-level §05 §6 renames only)
}

// program_schemas lifts a loaded program's decls into the Schema_Set shape the
// migration compiler consumes — the OLD side of a hot-reload (the running
// program) and the schema carry a v5 snapshot serializes (save_io.odin), so
// both consumers diff against the identical projection.
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

// schema_fields_of lifts loader Field_Decls into the kernel's Schema_Field
// shape, carrying every half the kernel reads: name and type spelling (both
// sides), the default token, and the v8 migrate halves (new side only — the
// kernel ignores them on the old side by construction).
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

// compile_migration runs the kernel over every schema pair the old and new
// worlds share, producing the whole-world Migration_Set or the first refusal.
// Data decls match by name — or by the new decl's prior_name when the type was
// renamed (§05 §6 decl-level form) — and OLD type spellings are canonicalized
// through the rename map before the diff, so a field typed by a renamed data
// type carries instead of tripping the retype verdict (a renamed type is the
// SAME type under a new name). A new data type with no old counterpart is
// additive (no old values exist, no plan needed); an old data type with no new
// counterpart drops with the values that referenced it (any surviving
// reference changes the referencing field's spelling and refuses there).
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
			continue // an ADDED data type: no old values exist, nothing to plan
		}
		canon := rename_schema_spellings(old_schema.fields, set.type_renames, allocator)
		plan, offender, err := diff_schemas(canon, schema_fields_of(decl.fields, allocator), allocator)
		if err != .None {
			return set, Migrate_Refusal{kind = .Kernel, scope = decl.name, offender = offender, verdict = err}
		}
		set.data_plans[decl.name] = plan
	}

	// The thing SET must match exactly — §09 §4 settles field deltas, not
	// decl-set deltas (see the header's settled-spec boundary).
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

// find_old_schema is the by-name lookup over an old schema list — a linear
// scan in declaration order, the kernel's own no-map discipline.
find_old_schema :: proc(schemas: []Old_Schema, name: string) -> (schema: Old_Schema, found: bool) {
	for candidate in schemas {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Old_Schema{}, false
}

// rename_schema_spellings canonicalizes an old schema's type spellings through
// the decl-level rename map, so the kernel compares both sides in the NEW
// world's names (a renamed type is the same type — without this, every field
// typed by it would read as a retype). Fields are copied; only spellings move.
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

// rename_spelling rewrites one type spelling through the rename map: an exact
// name maps directly, and a generic spelling (`[T]`, `Ctor[T]`) rewrites its
// constructor and its bracketed argument recursively, so `[OldStats]` and
// `Option[OldStats]` both canonicalize. A spelling the map does not cover is
// returned verbatim.
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

// migrate_world_version folds the compiled Migration_Set over a committed
// World_Version, producing the world the NEW program's schemas declare. Table
// order, row order, every stable Id, and next_id are PRESERVED — migration
// reshapes blackboards, never identity — so a Ref resolves to the same row
// after the fold and the spawn counter mints no colliding Id. Any per-row
// failure refuses the WHOLE migration (the caller keeps the old world): a
// partial world is never returned.
migrate_world_version :: proc(
	set: Migration_Set,
	world: World_Version,
	program: ^Program,
	allocator := context.allocator,
) -> (
	migrated: World_Version,
	refusal: Migrate_Refusal,
) {
	// The conversion interpreter: §05 §6 conversions are pure module fns of the
	// NEW program, so the interp reads no world, no tick, no input — an empty
	// version and resources satisfy its construction.
	empty_version := World_Version{}
	interp := new_interp(program, &empty_version, nil, empty(), migrate_time_resource(allocator), allocator)

	tables := make([]Version_Table, len(world.tables), allocator)
	for table, ti in world.tables {
		decl := program_thing(program, table.thing)
		if decl == nil {
			return {}, Migrate_Refusal{kind = .Thing_Set_Delta, scope = table.thing}
		}
		// A singleton flip is a decl-set delta in row-count clothing: the §08 §3
		// row-count-1 constraint cannot be reconciled mechanically, so it refuses.
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
	return World_Version{tick = world.tick, tables = tables}, Migrate_Refusal{}
}

// migrate_row_field executes ONE plan action over one row — the §09 §4 verdict
// table at the column level. Carry/Rename read the old column by its source
// name and deep-migrate it (a carried `stats: Stats` column still reshapes when
// Stats itself changed); Convert lifts the old column, runs the conversion fn,
// and lowers the result; Default decodes the field's declared default against
// the NEW program.
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

// migrate_column deep-migrates one committed COLUMN: a Record column reshapes
// through its data type's plan, a List migrates each element, a payload-
// carrying variant migrates its boxed payload, and every scalar (Int/Fixed/
// Bool/Vec2/Vec3/Ref/token/String) carries verbatim — enums have no @migrate
// channel (§05 §6), so a token is never rewritten.
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

// migrate_value is migrate_column's nested-Value twin — the same dispatch over
// the interpreter Value union, for values living inside records, lists, and
// variant payloads.
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
	case Variant_Value:
		return migrate_variant(set, program, interp, v, allocator)
	}
	return value, Migrate_Refusal{}
}

// migrate_record reshapes one composite record value through its data type's
// plan: the type name canonicalizes through the decl-level rename map, and —
// when a plan exists for the type — every new-schema field fills from its
// action exactly as a row column does (a typeless or engine record, which has
// no §3 Data_Decl and hence no plan, carries verbatim: its fields are engine
// shapes no user schema governs).
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

// migrate_list migrates each element of a `[T]` list column in list order —
// order is the list's canonical sequence, preserved verbatim.
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

// migrate_variant migrates a payload-carrying variant's boxed payload (the
// token itself carries verbatim — enums have no @migrate channel).
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

// run_conversion applies one §05 §6 conversion — a module-declared pure
// `fn(Old) -> New`, arity 1 by the compiler's admissibility gate — to an old
// value: bind the argument to the single param in a fresh scope and fold the
// body, exactly eval_user_call's discipline without a call node. ok is false
// when the fn is absent, not arity-1, or its body fails — the Convert_Failed
// refusal the caller surfaces.
run_conversion :: proc(interp: ^Interp, name: string, arg: Value) -> (value: Value, ok: bool) {
	fn := program_function(interp.program, name)
	if fn == nil || len(fn.params) != 1 {
		return nil, false
	}
	scope := Env{names = make(map[string]Value, interp.allocator)}
	scope.names[fn.params[0].name] = arg
	return eval_body(interp, fn.body, &scope)
}

// thing_field_decl finds a thing's declared field by name — the Default arm's
// lookup for the declared default token's Field_Decl.
thing_field_decl :: proc(decl: ^Thing_Decl, name: string) -> (fd: Field_Decl, found: bool) {
	for candidate in decl.fields {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Field_Decl{}, false
}

// migrate_time_resource is the inert Time record the conversion interpreter is
// constructed with — a §05 §6 conversion is pure and never reads it; the
// record only satisfies new_interp's signature.
migrate_time_resource :: proc(allocator := context.allocator) -> Record_Value {
	return Record_Value{type_name = "Time", fields = make(map[string]Value, allocator)}
}
