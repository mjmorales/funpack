package funpack_runtime

import "core:hash/xxhash"
import "core:slice"

Index_Entry :: struct {
	key:       Field_Value,
	key_bytes: []u8,
	id:        Id,
}

Index_Table_State :: struct {
	req:       Index_Req,
	entries:   []Index_Entry,
	supported: bool,
}

Index_State :: struct {
	tables: []Index_Table_State,
}

program_index_reqs :: proc(program: ^Program, allocator := context.allocator) -> []Index_Req {
	reqs := make([dynamic]Index_Req, 0, 4, allocator)
	for query in program.queries {
		for req in query.indexes {
			if !index_reqs_contain(reqs[:], req) {
				append(&reqs, req)
			}
		}
	}
	return reqs[:]
}

index_reqs_contain :: proc(reqs: []Index_Req, req: Index_Req) -> bool {
	for have in reqs {
		if have.kind == req.kind && have.thing == req.thing && have.field == req.field {
			return true
		}
	}
	return false
}

build_index_state :: proc(
	program: ^Program,
	version: ^World_Version,
	allocator := context.allocator,
) -> Index_State {
	reqs := program_index_reqs(program, allocator)
	tables := make([]Index_Table_State, len(reqs), allocator)
	for req, i in reqs {
		tables[i] = build_index_table(req, version, allocator)
	}
	return Index_State{tables = tables}
}

build_index_table :: proc(
	req: Index_Req,
	version: ^World_Version,
	allocator := context.allocator,
) -> Index_Table_State {
	table := version_find_table(version, req.thing)
	if table == nil {
		return Index_Table_State{req = req, entries = nil, supported = true}
	}
	entries := make([]Index_Entry, len(table.rows), allocator)
	for row, i in table.rows {
		key, present := row.fields[req.field]
		if !present {
			return Index_Table_State{req = req, entries = nil, supported = false}
		}
		key_bytes, encodable := index_key_bytes(key, allocator)
		if !encodable {
			return Index_Table_State{req = req, entries = nil, supported = false}
		}
		entries[i] = Index_Entry{key = key, key_bytes = key_bytes, id = row.id}
	}
	slice.sort_by(entries, index_entry_less)
	return Index_Table_State{req = req, entries = entries, supported = true}
}

index_entry_less :: proc(a, b: Index_Entry) -> bool {
	switch key_order := index_bytes_compare(a.key_bytes, b.key_bytes); key_order {
	case -1:
		return true
	case +1:
		return false
	}
	return a.id.raw < b.id.raw
}

index_bytes_compare :: proc(a, b: []u8) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return a[i] < b[i] ? -1 : +1
		}
	}
	if len(a) == len(b) {
		return 0
	}
	return len(a) < len(b) ? -1 : +1
}

fold_index_state :: proc(
	prior_state: Index_State,
	prior: ^World_Version,
	next: ^World_Version,
	allocator := context.allocator,
) -> Index_State {
	tables := make([]Index_Table_State, len(prior_state.tables), allocator)
	for prior_table, i in prior_state.tables {
		req := prior_table.req
		prior_rows := version_table_rows(prior, req.thing)
		next_rows := version_table_rows(next, req.thing)
		if prior_table.supported && rows_shared(prior_rows, next_rows) {
			tables[i] = prior_table
			continue
		}
		tables[i] = build_index_table(req, next, allocator)
	}
	return Index_State{tables = tables}
}

version_table_rows :: proc(version: ^World_Version, thing: string) -> []Row {
	table := version_find_table(version, thing)
	if table == nil {
		return nil
	}
	return table.rows
}

rows_shared :: proc(a, b: []Row) -> bool {
	return raw_data(a) == raw_data(b) && len(a) == len(b)
}

index_find_table :: proc(state: ^Index_State, kind: Query_Index_Kind, thing: string, field: string) -> ^Index_Table_State {
	for &table in state.tables {
		if table.req.kind == kind && table.req.thing == thing && table.req.field == field {
			return &table
		}
	}
	return nil
}

index_lookup :: proc(
	state: ^Index_State,
	thing: string,
	field: string,
	key: Field_Value,
	allocator := context.allocator,
) -> (
	ids: []Id,
	ok: bool,
) {
	table := index_find_table(state, .Index, thing, field)
	if table == nil || !table.supported {
		return nil, false
	}
	key_bytes, encodable := index_key_bytes(key, context.temp_allocator)
	if !encodable {
		return nil, false
	}
	out := make([dynamic]Id, 0, 4, allocator)
	for entry in table.entries {
		if index_bytes_compare(entry.key_bytes, key_bytes) == 0 {
			append(&out, entry.id)
		}
	}
	return out[:], true
}

Spatial_Hit :: struct {
	id:       Id,
	distance: Fixed,
}

spatial_within :: proc(
	state: ^Index_State,
	thing: string,
	field: string,
	origin: Field_Value,
	radius: Fixed,
	allocator := context.allocator,
) -> (
	hits: []Spatial_Hit,
	ok: bool,
) {
	table := index_find_table(state, .Spatial, thing, field)
	if table == nil || !table.supported {
		return nil, false
	}
	out := make([dynamic]Spatial_Hit, 0, len(table.entries), allocator)
	for entry in table.entries {
		distance, measurable := spatial_distance(origin, entry.key)
		if !measurable {
			return nil, false
		}
		if distance <= radius {
			append(&out, Spatial_Hit{id = entry.id, distance = distance})
		}
	}
	slice.sort_by(out[:], spatial_hit_less)
	return out[:], true
}

spatial_hit_less :: proc(a, b: Spatial_Hit) -> bool {
	if a.distance != b.distance {
		return a.distance < b.distance
	}
	return a.id.raw < b.id.raw
}

spatial_distance :: proc(origin: Field_Value, key: Field_Value) -> (distance: Fixed, ok: bool) {
	switch from in origin {
	case Vec2:
		at, is_vec2 := key.(Vec2)
		if !is_vec2 {
			return 0, false
		}
		return vec2_length(vec2_sub(at, from)), true
	case Vec3:
		at, is_vec3 := key.(Vec3)
		if !is_vec3 {
			return 0, false
		}
		return vec3_length(vec3_sub(at, from)), true
	case i64, Fixed, bool, string, Ref, Record_Value, List_Value, Map_Value, Variant_Value, String_Value:
		return 0, false
	}
	return 0, false
}

index_key_bytes :: proc(value: Field_Value, allocator := context.allocator) -> (bytes: []u8, ok: bool) {
	buf := make([dynamic]u8, 0, 16, allocator)
	if !append_field_key(&buf, value) {
		return nil, false
	}
	return buf[:], true
}

append_field_key :: proc(buf: ^[dynamic]u8, value: Field_Value) -> bool {
	switch v in value {
	case i64:
		append(buf, u8(Field_Tag.Int))
		append_biased_i64(buf, v)
	case Fixed:
		append(buf, u8(Field_Tag.Fixed))
		append_biased_i64(buf, i64(v))
	case bool:
		append(buf, u8(Field_Tag.Bool))
		append(buf, v ? u8(1) : u8(0))
	case string:
		append(buf, u8(Field_Tag.Variant))
		append(buf, ..transmute([]u8)v)
	case Vec2:
		append(buf, u8(Field_Tag.Vec2))
		append_biased_i64(buf, i64(v.x))
		append_biased_i64(buf, i64(v.y))
	case Vec3:
		append(buf, u8(Field_Tag.Vec3))
		append_biased_i64(buf, i64(v.x))
		append_biased_i64(buf, i64(v.y))
		append_biased_i64(buf, i64(v.z))
	case Ref:
		append(buf, u8(Field_Tag.Ref))
		append(buf, ..transmute([]u8)v.thing)
		append(buf, 0)
		append_biased_i64(buf, i64(v.id.raw))
	case Record_Value:
		return append_value_key(buf, v)
	case List_Value:
		return append_value_key(buf, v)
	case Map_Value:
		return append_value_key(buf, v)
	case Variant_Value:
		return append_value_key(buf, v)
	case String_Value:
		append(buf, u8(Field_Tag.String))
		append(buf, ..transmute([]u8)v.text)
	}
	return true
}

append_value_key :: proc(buf: ^[dynamic]u8, value: Value) -> bool {
	switch v in value {
	case i64:
		append(buf, u8(Field_Tag.Int))
		append_biased_i64(buf, v)
	case Fixed:
		append(buf, u8(Field_Tag.Fixed))
		append_biased_i64(buf, i64(v))
	case bool:
		append(buf, u8(Field_Tag.Bool))
		append(buf, v ? u8(1) : u8(0))
	case Vec2:
		append(buf, u8(Field_Tag.Vec2))
		append_biased_i64(buf, i64(v.x))
		append_biased_i64(buf, i64(v.y))
	case Vec3:
		append(buf, u8(Field_Tag.Vec3))
		append_biased_i64(buf, i64(v.x))
		append_biased_i64(buf, i64(v.y))
		append_biased_i64(buf, i64(v.z))
	case Ref:
		append(buf, u8(Field_Tag.Ref))
		append(buf, ..transmute([]u8)v.thing)
		append(buf, 0)
		append_biased_i64(buf, i64(v.id.raw))
	case Record_Value:
		append(buf, u8(Field_Tag.Record))
		append(buf, ..transmute([]u8)v.type_name)
		append(buf, 0)
		names := index_sorted_field_names(v.fields)
		defer delete(names)
		for name in names {
			append(buf, ..transmute([]u8)name)
			append(buf, 0)
			if !append_value_key(buf, v.fields[name]) {
				return false
			}
		}
	case List_Value:
		append(buf, u8(Field_Tag.List))
		for elem in v.elements {
			if !append_value_key(buf, elem) {
				return false
			}
		}
	case Map_Value:
		append(buf, u8(Field_Tag.Map))
		for entry in v.entries {
			if !append_value_key(buf, entry.key) {
				return false
			}
			if !append_value_key(buf, entry.value) {
				return false
			}
		}
	case Variant_Value:
		append(buf, u8(Field_Tag.Variant))
		append(buf, ..transmute([]u8)variant_to_token(v, context.temp_allocator))
		if v.payload != nil {
			append(buf, 0)
			return append_value_key(buf, v.payload^)
		}
	case String_Value:
		append(buf, u8(Field_Tag.String))
		append(buf, ..transmute([]u8)v.text)
	case Lambda_Value, Tuple_Value, Rng, Transform_Value, Pose_Value, Handle_Value, Nav_Value:
		return false
	}
	return true
}

index_sorted_field_names :: proc(fields: map[string]Value) -> [dynamic]string {
	names := make([dynamic]string, 0, len(fields))
	for name in fields {
		append(&names, name)
	}
	slice.sort(names[:])
	return names
}

append_biased_i64 :: proc(buf: ^[dynamic]u8, v: i64) {
	biased := u64(v) ~ (u64(1) << 63)
	for shift := uint(56); ; shift -= 8 {
		append(buf, u8(biased >> shift))
		if shift == 0 {
			break
		}
	}
}

index_table_digest :: proc(table: Index_Table_State) -> u64 {
	buf := make([dynamic]u8, 0, 256, context.temp_allocator)
	append(&buf, u8(table.req.kind))
	append(&buf, ..transmute([]u8)table.req.thing)
	append(&buf, 0)
	append(&buf, ..transmute([]u8)table.req.field)
	append(&buf, 0)
	append(&buf, table.supported ? u8(1) : u8(0))
	for entry in table.entries {
		append_biased_i64(&buf, i64(len(entry.key_bytes)))
		append(&buf, ..entry.key_bytes)
		append_biased_i64(&buf, i64(entry.id.raw))
	}
	return u64(xxhash.XXH64(buf[:]))
}

index_state_digest :: proc(state: Index_State) -> u64 {
	buf := make([dynamic]u8, 0, 8 * (len(state.tables) + 1), context.temp_allocator)
	append_biased_i64(&buf, i64(len(state.tables)))
	for table in state.tables {
		append_biased_i64(&buf, i64(index_table_digest(table)))
	}
	return u64(xxhash.XXH64(buf[:]))
}

index_states_equal :: proc(a, b: Index_State) -> bool {
	if len(a.tables) != len(b.tables) {
		return false
	}
	for table_a, i in a.tables {
		table_b := b.tables[i]
		if table_a.req != table_b.req || table_a.supported != table_b.supported {
			return false
		}
		if len(table_a.entries) != len(table_b.entries) {
			return false
		}
		for entry_a, j in table_a.entries {
			entry_b := table_b.entries[j]
			if entry_a.id != entry_b.id || index_bytes_compare(entry_a.key_bytes, entry_b.key_bytes) != 0 {
				return false
			}
		}
	}
	return true
}
