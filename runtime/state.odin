package funpack_runtime

Id :: struct {
	raw: Thing_Id,
}

Field_Value :: union {
	i64,
	Fixed,
	bool,
	string,
	Vec2,
	Vec3,
	Ref,
	Record_Value,
	List_Value,
	Map_Value,
	Variant_Value,
	String_Value,
}

Row :: struct {
	id:     Id,
	fields: map[string]Field_Value,
}

Ref :: struct {
	thing: string,
	id:    Id,
}

Version_Table :: struct {
	thing:     string,
	singleton: bool,
	rows:      []Row,
	next_id:   Thing_Id,
}

World_Version :: struct {
	tick:     int,
	tables:   []Version_Table,
	tilemaps: []Tile_Layer,
}

initial_version :: proc(world: World, allocator := context.allocator) -> World_Version {
	tables := make([]Version_Table, len(world.tables), allocator)
	for table, i in world.tables {
		tables[i] = Version_Table {
			thing     = table.thing,
			singleton = table.singleton,
			rows      = nil,
			next_id   = table.next_id,
		}
	}
	return World_Version{tick = -1, tables = tables, tilemaps = world.tilemaps}
}

commit_version :: proc(
	prior: World_Version,
	changed: map[string]Version_Table,
	allocator := context.allocator,
) -> World_Version {
	tables := make([]Version_Table, len(prior.tables), allocator)
	for table, i in prior.tables {
		if replacement, ok := changed[table.thing]; ok {
			tables[i] = replacement
		} else {
			tables[i] = table
		}
	}
	return World_Version{tick = prior.tick + 1, tables = tables, tilemaps = prior.tilemaps}
}

version_find_table :: proc(version: ^World_Version, thing: string) -> ^Version_Table {
	for &table in version.tables {
		if table.thing == thing {
			return &table
		}
	}
	return nil
}

View :: struct {
	thing: string,
	rows:  []Row,
}

view_of_type :: proc(version: ^World_Version, thing: string) -> View {
	table := version_find_table(version, thing)
	if table == nil {
		return View{thing = thing, rows = nil}
	}
	return View{thing = thing, rows = table.rows}
}

view_count :: proc(view: View) -> int {
	return len(view.rows)
}

view_at :: proc(view: View, i: int) -> (row: Row, ok: bool) {
	if i < 0 || i >= len(view.rows) {
		return {}, false
	}
	return view.rows[i], true
}

view_ref :: proc(view: View, i: int) -> (ref: Ref, ok: bool) {
	row, in_range := view_at(view, i)
	if !in_range {
		return {}, false
	}
	return Ref{thing = view.thing, id = row.id}, true
}

view_resolve :: proc(view: View, ref: Ref) -> (row: Row, some: bool) {
	if ref.thing != view.thing {
		return {}, false
	}
	idx, found := find_row_by_id(view.rows, ref.id)
	if !found {
		return {}, false
	}
	return view.rows[idx], true
}

resolve_ref :: proc(version: ^World_Version, ref: Ref) -> (row: Row, some: bool) {
	table := version_find_table(version, ref.thing)
	if table == nil {
		return {}, false
	}
	idx, found := find_row_by_id(table.rows, ref.id)
	if !found {
		return {}, false
	}
	return table.rows[idx], true
}

singleton_row :: proc(version: ^World_Version, thing: string) -> (row: Row, ok: bool) {
	table := version_find_table(version, thing)
	if table == nil || !table.singleton {
		return {}, false
	}
	if len(table.rows) != 1 {
		return {}, false
	}
	return table.rows[0], true
}

row_field :: proc(row: Row, name: string) -> (value: Field_Value, ok: bool) {
	value, ok = row.fields[name]
	return
}

row_ref :: proc(row: Row, name: string) -> (ref: Ref, ok: bool) {
	value, present := row.fields[name]
	if !present {
		return {}, false
	}
	ref, ok = value.(Ref)
	return
}

find_row_by_id :: proc(rows: []Row, id: Id) -> (idx: int, found: bool) {
	lo, hi := 0, len(rows)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if rows[mid].id.raw < id.raw {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(rows) && rows[lo].id.raw == id.raw {
		return lo, true
	}
	return 0, false
}

view_of :: proc(thing: string, blackboards: []map[string]Field_Value, allocator := context.allocator) -> View {
	rows := make([]Row, len(blackboards), allocator)
	for fields, i in blackboards {
		rows[i] = Row{id = Id{raw = Thing_Id(i)}, fields = fields}
	}
	return View{thing = thing, rows = rows}
}

vec2_add :: proc(a, b: Vec2) -> Vec2 {
	return Vec2{fixed_add(a.x, b.x), fixed_add(a.y, b.y)}
}

vec2_sub :: proc(a, b: Vec2) -> Vec2 {
	return Vec2{fixed_sub(a.x, b.x), fixed_sub(a.y, b.y)}
}

vec2_scale :: proc(v: Vec2, s: Fixed) -> Vec2 {
	return Vec2{fixed_mul(v.x, s), fixed_mul(v.y, s)}
}

vec2_dot :: proc(a, b: Vec2) -> Fixed {
	return fixed_add(fixed_mul(a.x, b.x), fixed_mul(a.y, b.y))
}

vec2_length :: proc(v: Vec2) -> Fixed {
	return fixed_sqrt(vec2_dot(v, v))
}

vec2_normalize :: proc(v: Vec2) -> (unit: Vec2, ok: bool) {
	length := vec2_length(v)
	if length == 0 {
		return VEC2_ZERO, false
	}
	return Vec2{fixed_div(v.x, length), fixed_div(v.y, length)}, true
}

vec3_normalize :: proc(v: Vec3) -> (unit: Vec3, ok: bool) {
	length := vec3_length(v)
	if length == 0 {
		return Vec3{}, false
	}
	return Vec3{fixed_div(v.x, length), fixed_div(v.y, length), fixed_div(v.z, length)}, true
}

world_versions_equal :: proc(a, b: World_Version) -> bool {
	if a.tick != b.tick || len(a.tables) != len(b.tables) {
		return false
	}
	for table_a, i in a.tables {
		table_b := b.tables[i]
		if table_a.thing != table_b.thing || len(table_a.rows) != len(table_b.rows) {
			return false
		}
		for row_a, j in table_a.rows {
			row_b := table_b.rows[j]
			if row_a.id != row_b.id || !blackboards_equal(row_a.fields, row_b.fields) {
				return false
			}
		}
	}
	if len(a.tilemaps) != len(b.tilemaps) {
		return false
	}
	for layer_a, i in a.tilemaps {
		if !tile_layers_equal(layer_a, b.tilemaps[i]) {
			return false
		}
	}
	return true
}

blackboards_equal :: proc(a, b: map[string]Field_Value) -> bool {
	if len(a) != len(b) {
		return false
	}
	for key, value_a in a {
		value_b, present := b[key]
		if !present || !field_values_equal(value_a, value_b) {
			return false
		}
	}
	return true
}

field_values_equal :: proc(a, b: Field_Value) -> bool {
	return values_equal(field_value_to_value(a), field_value_to_value(b))
}
