package funpack_runtime

import "core:encoding/endian"
import "core:hash/xxhash"
import "core:os"
import "core:slice"
import "core:strings"

SAVE_SNAPSHOT_SCHEMA_VERSION :: u64(7)

SAVE_SNAPSHOT_MAGIC :: u64(0x_31_30_50_41_4e_53_50_46)

Save_Snapshot :: struct {
	bytes:        []u8,
	content_hash: u64,
}

Save_Store :: struct {
	backend: Save_Backend,
}

Save_Backend :: union {
	In_Memory_Store,
	On_Disk_Store,
}

In_Memory_Store :: struct {
	slots:    map[string]Save_Snapshot,
	settings: Maybe(Record_Value),
}

On_Disk_Store :: struct {
	root: string,
}

new_in_memory_store :: proc(allocator := context.allocator) -> Save_Store {
	return Save_Store {
		backend = In_Memory_Store {
			slots = make(map[string]Save_Snapshot, allocator),
			settings = nil,
		},
	}
}

new_on_disk_store :: proc(root: string) -> Save_Store {
	return Save_Store{backend = On_Disk_Store{root = root}}
}

store_write_slot :: proc(
	store: ^Save_Store,
	slot: string,
	snapshot: Save_Snapshot,
	allocator := context.allocator,
) -> bool {
	switch &backend in store.backend {
	case In_Memory_Store:
		backend.slots[strings.clone(slot, allocator)] = snapshot
		return true
	case On_Disk_Store:
		path := slot_path(backend.root, slot, allocator)
		return os.write_entire_file_from_string(path, string(snapshot.bytes)) == nil
	}
	return false
}

store_read_slot :: proc(
	store: ^Save_Store,
	slot: string,
	allocator := context.allocator,
) -> (
	snapshot: Save_Snapshot,
	ok: bool,
) {
	switch backend in store.backend {
	case In_Memory_Store:
		snapshot, ok = backend.slots[slot]
		return snapshot, ok
	case On_Disk_Store:
		path := slot_path(backend.root, slot, allocator)
		bytes, read_err := os.read_entire_file_from_path(path, allocator)
		if read_err != nil {
			return {}, false
		}
		return Save_Snapshot{bytes = bytes, content_hash = u64(xxhash.XXH64(bytes))}, true
	}
	return {}, false
}

store_write_settings :: proc(
	store: ^Save_Store,
	settings: Record_Value,
	allocator := context.allocator,
) -> bool {
	switch &backend in store.backend {
	case In_Memory_Store:
		backend.settings = clone_record_value(settings, allocator)
		return true
	case On_Disk_Store:
		bytes := serialize_settings(settings, allocator)
		path := settings_path(backend.root, allocator)
		return os.write_entire_file_from_string(path, string(bytes)) == nil
	}
	return false
}

store_read_settings :: proc(
	store: ^Save_Store,
	allocator := context.allocator,
) -> (
	settings: Record_Value,
	ok: bool,
) {
	switch backend in store.backend {
	case In_Memory_Store:
		rec, present := backend.settings.?
		return rec, present
	case On_Disk_Store:
		path := settings_path(backend.root, allocator)
		bytes, read_err := os.read_entire_file_from_path(path, allocator)
		if read_err != nil {
			return {}, false
		}
		return deserialize_settings(bytes, allocator)
	}
	return {}, false
}

slot_path :: proc(root, slot: string, allocator := context.allocator) -> string {
	return strings.concatenate({root, "/", slot, ".snap"}, allocator)
}

settings_path :: proc(root: string, allocator := context.allocator) -> string {
	return strings.concatenate({root, "/settings.snap"}, allocator)
}

Persist_Outcome :: struct {
	signal: string,
	slot:   string,
	ok:     bool,
}

Persist_Effects :: struct {
	outcomes: []Persist_Outcome,
	swap:     Maybe(World_Version),
}

process_persist_commands :: proc(
	store: ^Save_Store,
	program: ^Program,
	committed: World_Version,
	commands: []Record_Value,
	allocator := context.allocator,
) -> Persist_Effects {
	outcomes := make([dynamic]Persist_Outcome, allocator)
	swap: Maybe(World_Version) = nil
	for command in commands {
		switch command.type_name {
		case "Save":
			ok := apply_save(store, program, committed, persist_slot(command), allocator)
			append(&outcomes, Persist_Outcome{signal = "Saved", slot = strings.clone(persist_slot(command), allocator), ok = ok})
		case "Restore":
			version, ok := apply_restore(store, program, persist_slot(command), allocator)
			if ok {
				swap = version
			}
			append(&outcomes, Persist_Outcome{signal = "Restored", slot = strings.clone(persist_slot(command), allocator), ok = ok})
		case "ApplySettings":
			ok := apply_settings_command(store, command, allocator)
			append(&outcomes, Persist_Outcome{signal = "SettingsApplied", slot = "", ok = ok})
		}
	}
	return Persist_Effects{outcomes = outcomes[:], swap = swap}
}

persist_slot :: proc(command: Record_Value) -> string {
	slot, present := command.fields["slot"]
	if !present {
		return ""
	}
	if str, is_str := slot.(String_Value); is_str {
		return str.text
	}
	return ""
}

apply_save :: proc(
	store: ^Save_Store,
	program: ^Program,
	committed: World_Version,
	slot: string,
	allocator := context.allocator,
) -> bool {
	bytes := serialize_snapshot(program, committed, allocator)
	snapshot := Save_Snapshot{bytes = bytes, content_hash = u64(xxhash.XXH64(bytes))}
	return store_write_slot(store, slot, snapshot, allocator)
}

apply_restore :: proc(
	store: ^Save_Store,
	program: ^Program,
	slot: string,
	allocator := context.allocator,
) -> (
	version: World_Version,
	ok: bool,
) {
	snapshot, read_ok := store_read_slot(store, slot, allocator)
	if !read_ok {
		return {}, false
	}
	if u64(xxhash.XXH64(snapshot.bytes)) != snapshot.content_hash {
		return {}, false
	}
	saved, old_schemas, saved_delta, parse_ok := deserialize_snapshot(snapshot.bytes, allocator)
	if !parse_ok {
		return {}, false
	}
	set, compile_refusal := compile_migration(old_schemas, program, allocator)
	if compile_refusal.kind != .None {
		return {}, false
	}
	migrated, migrate_refusal := migrate_world_version(set, saved, program, saved_delta, allocator)
	if migrate_refusal.kind != .None {
		return {}, false
	}
	return migrated, true
}

apply_settings_command :: proc(
	store: ^Save_Store,
	command: Record_Value,
	allocator := context.allocator,
) -> bool {
	settings, present := command.fields["settings"]
	if !present {
		return false
	}
	rec, is_rec := settings.(Record_Value)
	if !is_rec {
		return false
	}
	return store_write_settings(store, rec, allocator)
}

outcome_to_signal :: proc(outcome: Persist_Outcome, allocator := context.allocator) -> Value {
	payload := new(Value, allocator)
	payload^ = Record_Value{type_name = "", fields = make(map[string]Value, allocator)}
	result := Variant_Value {
		enum_type = "Result",
		case_name = outcome.ok ? "Ok" : "Err",
		payload   = payload,
	}
	fields := make(map[string]Value, allocator)
	fields["result"] = result
	if outcome.slot != "" {
		fields["slot"] = String_Value{text = strings.clone(outcome.slot, allocator)}
	}
	return Record_Value{type_name = outcome.signal, fields = fields}
}

Persist_Carrier :: struct {
	store:   ^Save_Store,
	pending: []Persist_Outcome,
	swap:    Maybe(World_Version),
}

new_persist_carrier :: proc(store: ^Save_Store) -> Persist_Carrier {
	return Persist_Carrier{store = store, pending = nil, swap = nil}
}

step_tick_persist :: proc(
	program: ^Program,
	prior: World_Version,
	input: Input,
	time: Record_Value,
	carrier: Persist_Carrier,
	allocator := context.allocator,
	rng: ^Rng = nil,
	commit_allocator := context.allocator,
	reclaim_live := false,
) -> (
	version: World_Version,
	next_carrier: Persist_Carrier,
) {
	base := prior
	if swap, has_swap := carrier.swap.?; has_swap {
		base = swap
	}

	state := new_tick_state(base, allocator, commit_allocator)
	if rng != nil {
		state.rng = rng^
	}
	seed_outcome_signals(&state, carrier.pending, allocator)

	base_version := base
	interp := new_interp(program, &base_version, &state, input, time, allocator)
	run_pipeline_fold(&interp, &state, program)
	apply_spawn_batch(&state)
	if rng != nil {
		rng^ = state.rng
	}
	committed := commit_tick_state(base, &state, commit_allocator)

	effects := process_persist_commands(carrier.store, program, committed, state.persist_commands[:], commit_allocator)

	if swap, has_swap := effects.swap.?; has_swap {
		swap.tilemaps = committed.tilemaps
		effects.swap = swap
	}

	if reclaim_live {
		free_persist_outcomes(carrier.pending, commit_allocator)

		// Generational reclaim: base frees structure-only (committed aliases its maps); prior frees fully only when a swap made it distinct from base.
		free_superseded_maps(state.superseded, commit_allocator)
		free_version_structure(base, commit_allocator)
		free_version_tilemaps(base, committed, program, commit_allocator)

		if !world_versions_same_identity(base, prior) {
			free_version_fully(prior, commit_allocator)
		}
	}

	return committed, Persist_Carrier {
			store = carrier.store,
			pending = effects.outcomes,
			swap = effects.swap,
		}
}

world_versions_same_identity :: proc(a, b: World_Version) -> bool {
	return raw_data(a.tables) == raw_data(b.tables)
}

free_persist_outcomes :: proc(outcomes: []Persist_Outcome, allocator := context.allocator) {
	for outcome in outcomes {
		if outcome.slot != "" {
			delete(outcome.slot, allocator)
		}
	}
	delete(outcomes, allocator)
}

seed_outcome_signals :: proc(
	state: ^Tick_State,
	outcomes: []Persist_Outcome,
	allocator := context.allocator,
) {
	for outcome in outcomes {
		signal := outcome_to_signal(outcome, allocator)
		existing := state.mailbox.by_type[outcome.signal]
		combined := make([]Value, len(existing) + 1, allocator)
		copy(combined, existing)
		combined[len(existing)] = signal
		state.mailbox.by_type[outcome.signal] = combined
	}
}

serialize_snapshot :: proc(program: ^Program, version: World_Version, allocator := context.allocator) -> []u8 {
	buf := make([dynamic]u8, allocator)
	snap_put_u64(&buf, SAVE_SNAPSHOT_MAGIC)
	snap_put_u64(&buf, SAVE_SNAPSHOT_SCHEMA_VERSION)
	snap_put_u64(&buf, u64(i64(version.tick)))
	snap_put_u64(&buf, u64(len(program.data)))
	for &decl in program.data {
		snap_put_string(&buf, decl.name)
		snap_write_field_schema(&buf, decl.fields)
	}
	snap_put_u64(&buf, u64(len(program.things)))
	for &decl in program.things {
		snap_put_string(&buf, decl.name)
		snap_write_field_schema(&buf, decl.fields)
	}
	snap_put_u64(&buf, u64(len(version.tables)))
	for table in version.tables {
		snap_put_string(&buf, table.thing)
		append(&buf, table.singleton ? u8(1) : u8(0))
		snap_put_u64(&buf, u64(table.next_id))
		snap_put_u64(&buf, u64(len(table.rows)))
		for row in table.rows {
			snap_write_row(&buf, row)
		}
	}
	snap_write_tile_carry(&buf, tile_carry_delta(program.tilemaps, version.tilemaps, allocator))
	return buf[:]
}

snap_write_tile_carry :: proc(buf: ^[dynamic]u8, delta: Tile_Carry_Delta) {
	snap_put_u64(buf, u64(len(delta.edits)))
	for edit in delta.edits {
		snap_put_string(buf, edit.layer_name)
		snap_put_u64(buf, u64(i64(edit.col)))
		snap_put_u64(buf, u64(i64(edit.row)))
		snap_put_string(buf, edit.tile_name)
	}
}

snap_write_row :: proc(buf: ^[dynamic]u8, row: Row) {
	snap_put_u64(buf, u64(row.id.raw))
	names := snap_sorted_field_names(row.fields)
	snap_put_u64(buf, u64(len(names)))
	for name in names {
		snap_put_string(buf, name)
		snap_write_field_value(buf, row.fields[name])
	}
}

snap_write_field_value :: proc(buf: ^[dynamic]u8, value: Field_Value) {
	switch v in value {
	case i64:
		append(buf, u8(Field_Tag.Int))
		snap_put_u64(buf, u64(v))
	case Fixed:
		append(buf, u8(Field_Tag.Fixed))
		snap_put_u64(buf, u64(i64(v)))
	case bool:
		append(buf, u8(Field_Tag.Bool))
		append(buf, v ? u8(1) : u8(0))
	case string:
		append(buf, u8(Field_Tag.Variant))
		snap_put_string(buf, v)
	case Vec2:
		append(buf, u8(Field_Tag.Vec2))
		snap_put_u64(buf, u64(i64(v.x)))
		snap_put_u64(buf, u64(i64(v.y)))
	case Vec3:
		append(buf, u8(Field_Tag.Vec3))
		snap_put_u64(buf, u64(i64(v.x)))
		snap_put_u64(buf, u64(i64(v.y)))
		snap_put_u64(buf, u64(i64(v.z)))
	case Ref:
		append(buf, u8(Field_Tag.Ref))
		snap_put_string(buf, v.thing)
		snap_put_u64(buf, u64(v.id.raw))
	case Record_Value:
		append(buf, u8(Field_Tag.Record))
		snap_write_record(buf, v)
	case List_Value:
		append(buf, u8(Field_Tag.List))
		snap_write_list(buf, v)
	case Map_Value:
		append(buf, u8(Field_Tag.Map))
		snap_write_map(buf, v)
	case Variant_Value:
		if v.payload == nil {
			append(buf, u8(Field_Tag.Variant))
			snap_put_string(buf, variant_to_token(v, context.temp_allocator))
		} else {
			append(buf, u8(Field_Tag.Variant_Payload))
			snap_put_string(buf, variant_to_token(v, context.temp_allocator))
			snap_write_column_value(buf, v.payload^)
		}
	case String_Value:
		append(buf, u8(Field_Tag.String))
		snap_put_string(buf, v.text)
	}
}

snap_write_record :: proc(buf: ^[dynamic]u8, rec: Record_Value) {
	snap_put_string(buf, rec.type_name)
	names := snap_sorted_value_field_names(rec.fields)
	snap_put_u64(buf, u64(len(names)))
	for name in names {
		snap_put_string(buf, name)
		snap_write_column_value(buf, rec.fields[name])
	}
}

snap_write_list :: proc(buf: ^[dynamic]u8, list: List_Value) {
	snap_put_u64(buf, u64(len(list.elements)))
	for elem in list.elements {
		snap_write_column_value(buf, elem)
	}
}

snap_write_column_value :: proc(buf: ^[dynamic]u8, v: Value) {
	switch x in v {
	case i64:
		append(buf, u8(Field_Tag.Int))
		snap_put_u64(buf, u64(x))
	case Fixed:
		append(buf, u8(Field_Tag.Fixed))
		snap_put_u64(buf, u64(i64(x)))
	case bool:
		append(buf, u8(Field_Tag.Bool))
		append(buf, x ? u8(1) : u8(0))
	case Vec2:
		append(buf, u8(Field_Tag.Vec2))
		snap_put_u64(buf, u64(i64(x.x)))
		snap_put_u64(buf, u64(i64(x.y)))
	case Vec3:
		append(buf, u8(Field_Tag.Vec3))
		snap_put_u64(buf, u64(i64(x.x)))
		snap_put_u64(buf, u64(i64(x.y)))
		snap_put_u64(buf, u64(i64(x.z)))
	case Ref:
		append(buf, u8(Field_Tag.Ref))
		snap_put_string(buf, x.thing)
		snap_put_u64(buf, u64(x.id.raw))
	case Variant_Value:
		if x.payload != nil {
			append(buf, u8(Field_Tag.Variant_Payload))
			snap_put_string(buf, variant_to_token(x, context.temp_allocator))
			snap_write_column_value(buf, x.payload^)
		} else {
			append(buf, u8(Field_Tag.Variant))
			snap_put_string(buf, variant_to_token(x, context.temp_allocator))
		}
	case Record_Value:
		append(buf, u8(Field_Tag.Record))
		snap_write_record(buf, x)
	case List_Value:
		append(buf, u8(Field_Tag.List))
		snap_write_list(buf, x)
	case Map_Value:
		append(buf, u8(Field_Tag.Map))
		snap_write_map(buf, x)
	case String_Value:
		append(buf, u8(Field_Tag.String))
		snap_put_string(buf, x.text)
	case Lambda_Value, Tuple_Value, Rng, Transform_Value, Pose_Value, Handle_Value, Nav_Value:
	}
}

snap_write_map :: proc(buf: ^[dynamic]u8, m: Map_Value) {
	snap_put_u64(buf, u64(len(m.entries)))
	for entry in m.entries {
		snap_write_column_value(buf, entry.key)
		snap_write_column_value(buf, entry.value)
	}
}

deserialize_snapshot :: proc(
	bytes: []u8,
	allocator := context.allocator,
) -> (
	version: World_Version,
	schemas: Schema_Set,
	carry: Tile_Carry_Delta,
	ok: bool,
) {
	cur := Snap_Cursor{data = bytes, pos = 0}
	magic := snap_get_u64(&cur) or_return
	if magic != SAVE_SNAPSHOT_MAGIC {
		return {}, {}, {}, false
	}
	ver := snap_get_u64(&cur) or_return
	if ver != SAVE_SNAPSHOT_SCHEMA_VERSION {
		return {}, {}, {}, false
	}
	tick := i64(snap_get_u64(&cur) or_return)
	schemas.data = snap_read_schema_block(&cur, allocator) or_return
	schemas.things = snap_read_schema_block(&cur, allocator) or_return
	table_count := snap_get_u64(&cur) or_return
	tables := make([]Version_Table, int(table_count), allocator)
	for ti in 0 ..< int(table_count) {
		thing := snap_get_string(&cur, allocator) or_return
		singleton_byte := snap_get_u8(&cur) or_return
		next_id := Thing_Id(snap_get_u64(&cur) or_return)
		row_count := snap_get_u64(&cur) or_return
		rows := make([]Row, int(row_count), allocator)
		for ri in 0 ..< int(row_count) {
			rows[ri] = snap_read_row(&cur, allocator) or_return
		}
		tables[ti] = Version_Table {
			thing     = thing,
			singleton = singleton_byte != 0,
			rows      = rows,
			next_id   = next_id,
		}
	}
	carry = snap_read_tile_carry(&cur, allocator) or_return
	return World_Version{tick = int(tick), tables = tables}, schemas, carry, true
}

snap_read_tile_carry :: proc(
	cur: ^Snap_Cursor,
	allocator := context.allocator,
) -> (
	delta: Tile_Carry_Delta,
	ok: bool,
) {
	count := snap_get_u64(cur) or_return
	edits := make([]Tile_Carry_Edit, int(count), allocator)
	for i in 0 ..< int(count) {
		layer_name := snap_get_string(cur, allocator) or_return
		col := int(i64(snap_get_u64(cur) or_return))
		row := int(i64(snap_get_u64(cur) or_return))
		tile_name := snap_get_string(cur, allocator) or_return
		edits[i] = Tile_Carry_Edit {
			layer_name = layer_name,
			col        = col,
			row        = row,
			tile_name  = tile_name,
		}
	}
	return Tile_Carry_Delta{edits = edits}, true
}

snap_write_field_schema :: proc(buf: ^[dynamic]u8, fields: []Field_Decl) {
	snap_put_u64(buf, u64(len(fields)))
	for fd in fields {
		snap_put_string(buf, fd.name)
		snap_put_string(buf, fd.type)
	}
}

snap_read_schema_block :: proc(
	cur: ^Snap_Cursor,
	allocator := context.allocator,
) -> (
	schemas: []Old_Schema,
	ok: bool,
) {
	count := snap_get_u64(cur) or_return
	out := make([]Old_Schema, int(count), allocator)
	for i in 0 ..< int(count) {
		name := snap_get_string(cur, allocator) or_return
		field_count := snap_get_u64(cur) or_return
		fields := make([]Schema_Field, int(field_count), allocator)
		for j in 0 ..< int(field_count) {
			field_name := snap_get_string(cur, allocator) or_return
			field_type := snap_get_string(cur, allocator) or_return
			fields[j] = Schema_Field{name = field_name, type_spelling = field_type}
		}
		out[i] = Old_Schema{name = name, fields = fields}
	}
	return out, true
}

snap_read_row :: proc(cur: ^Snap_Cursor, allocator := context.allocator) -> (row: Row, ok: bool) {
	id_raw := snap_get_u64(cur) or_return
	field_count := snap_get_u64(cur) or_return
	fields := make(map[string]Field_Value, int(field_count), allocator)
	for _ in 0 ..< int(field_count) {
		name := snap_get_string(cur, allocator) or_return
		value := snap_read_field_value(cur, allocator) or_return
		fields[name] = value
	}
	return Row{id = Id{raw = Thing_Id(id_raw)}, fields = fields}, true
}

snap_read_field_value :: proc(
	cur: ^Snap_Cursor,
	allocator := context.allocator,
) -> (
	fv: Field_Value,
	ok: bool,
) {
	tag := snap_get_u8(cur) or_return
	switch Field_Tag(tag) {
	case .Int:
		return i64(snap_get_u64(cur) or_return), true
	case .Fixed:
		return Fixed(i64(snap_get_u64(cur) or_return)), true
	case .Bool:
		return (snap_get_u8(cur) or_return) != 0, true
	case .Variant:
		return snap_get_string(cur, allocator) or_return, true
	case .Vec2:
		x := Fixed(i64(snap_get_u64(cur) or_return))
		y := Fixed(i64(snap_get_u64(cur) or_return))
		return Vec2{x = x, y = y}, true
	case .Vec3:
		x := Fixed(i64(snap_get_u64(cur) or_return))
		y := Fixed(i64(snap_get_u64(cur) or_return))
		z := Fixed(i64(snap_get_u64(cur) or_return))
		return Vec3{x = x, y = y, z = z}, true
	case .Ref:
		thing := snap_get_string(cur, allocator) or_return
		raw := snap_get_u64(cur) or_return
		return Ref{thing = thing, id = Id{raw = Thing_Id(raw)}}, true
	case .Record:
		rec := snap_read_record(cur, allocator) or_return
		return rec, true
	case .List:
		list := snap_read_list(cur, allocator) or_return
		return list, true
	case .Map:
		m := snap_read_map(cur, allocator) or_return
		return m, true
	case .Variant_Payload:
		token := snap_get_string(cur, allocator) or_return
		inner := snap_read_column_value(cur, allocator) or_return
		payload := new(Value, allocator)
		payload^ = inner
		variant := variant_from_token(token)
		variant.payload = payload
		return variant, true
	case .String:
		text := snap_get_string(cur, allocator) or_return
		return String_Value{text = text}, true
	}
	return nil, false
}

snap_read_record :: proc(
	cur: ^Snap_Cursor,
	allocator := context.allocator,
) -> (
	rec: Record_Value,
	ok: bool,
) {
	type_name := snap_get_string(cur, allocator) or_return
	field_count := snap_get_u64(cur) or_return
	fields := make(map[string]Value, int(field_count), allocator)
	for _ in 0 ..< int(field_count) {
		name := snap_get_string(cur, allocator) or_return
		value := snap_read_column_value(cur, allocator) or_return
		fields[name] = value
	}
	return Record_Value{type_name = type_name, fields = fields}, true
}

snap_read_list :: proc(
	cur: ^Snap_Cursor,
	allocator := context.allocator,
) -> (
	list: List_Value,
	ok: bool,
) {
	count := snap_get_u64(cur) or_return
	elements := make([]Value, int(count), allocator)
	for i in 0 ..< int(count) {
		elements[i] = snap_read_column_value(cur, allocator) or_return
	}
	return List_Value{elements = elements}, true
}

snap_read_map :: proc(
	cur: ^Snap_Cursor,
	allocator := context.allocator,
) -> (
	m: Map_Value,
	ok: bool,
) {
	count := snap_get_u64(cur) or_return
	entries := make([]Map_Entry, int(count), allocator)
	for i in 0 ..< int(count) {
		key := snap_read_column_value(cur, allocator) or_return
		value := snap_read_column_value(cur, allocator) or_return
		entries[i] = Map_Entry{key = key, value = value}
	}
	return Map_Value{entries = entries}, true
}

snap_read_column_value :: proc(
	cur: ^Snap_Cursor,
	allocator := context.allocator,
) -> (
	v: Value,
	ok: bool,
) {
	tag := snap_get_u8(cur) or_return
	switch Field_Tag(tag) {
	case .Int:
		return i64(snap_get_u64(cur) or_return), true
	case .Fixed:
		return Fixed(i64(snap_get_u64(cur) or_return)), true
	case .Bool:
		return (snap_get_u8(cur) or_return) != 0, true
	case .Vec2:
		x := Fixed(i64(snap_get_u64(cur) or_return))
		y := Fixed(i64(snap_get_u64(cur) or_return))
		return Vec2{x = x, y = y}, true
	case .Vec3:
		x := Fixed(i64(snap_get_u64(cur) or_return))
		y := Fixed(i64(snap_get_u64(cur) or_return))
		z := Fixed(i64(snap_get_u64(cur) or_return))
		return Vec3{x = x, y = y, z = z}, true
	case .Ref:
		thing := snap_get_string(cur, allocator) or_return
		raw := snap_get_u64(cur) or_return
		return Ref{thing = thing, id = Id{raw = Thing_Id(raw)}}, true
	case .Variant:
		token := snap_get_string(cur, allocator) or_return
		return variant_from_token(token), true
	case .Variant_Payload:
		token := snap_get_string(cur, allocator) or_return
		inner := snap_read_column_value(cur, allocator) or_return
		payload := new(Value, allocator)
		payload^ = inner
		variant := variant_from_token(token)
		variant.payload = payload
		return variant, true
	case .String:
		text := snap_get_string(cur, allocator) or_return
		return String_Value{text = text}, true
	case .Record:
		rec := snap_read_record(cur, allocator) or_return
		return rec, true
	case .List:
		list := snap_read_list(cur, allocator) or_return
		return list, true
	case .Map:
		m := snap_read_map(cur, allocator) or_return
		return m, true
	}
	return nil, false
}

serialize_settings :: proc(settings: Record_Value, allocator := context.allocator) -> []u8 {
	buf := make([dynamic]u8, allocator)
	snap_put_u64(&buf, SAVE_SNAPSHOT_MAGIC)
	snap_put_u64(&buf, SAVE_SNAPSHOT_SCHEMA_VERSION)
	snap_write_record(&buf, settings)
	return buf[:]
}

deserialize_settings :: proc(
	bytes: []u8,
	allocator := context.allocator,
) -> (
	settings: Record_Value,
	ok: bool,
) {
	cur := Snap_Cursor{data = bytes, pos = 0}
	magic := snap_get_u64(&cur) or_return
	if magic != SAVE_SNAPSHOT_MAGIC {
		return {}, false
	}
	ver := snap_get_u64(&cur) or_return
	if ver != SAVE_SNAPSHOT_SCHEMA_VERSION {
		return {}, false
	}
	return snap_read_record(&cur, allocator)
}

Snap_Cursor :: struct {
	data: []u8,
	pos:  int,
}

snap_get_u8 :: proc(cur: ^Snap_Cursor) -> (b: u8, ok: bool) {
	if cur.pos + 1 > len(cur.data) {
		return 0, false
	}
	b = cur.data[cur.pos]
	cur.pos += 1
	return b, true
}

snap_get_u64 :: proc(cur: ^Snap_Cursor) -> (v: u64, ok: bool) {
	if cur.pos + 8 > len(cur.data) {
		return 0, false
	}
	v, ok = endian.get_u64(cur.data[cur.pos:cur.pos + 8], .Little)
	if !ok {
		return 0, false
	}
	cur.pos += 8
	return v, true
}

snap_get_string :: proc(
	cur: ^Snap_Cursor,
	allocator := context.allocator,
) -> (
	s: string,
	ok: bool,
) {
	length := int(snap_get_u64(cur) or_return)
	if cur.pos + length > len(cur.data) {
		return "", false
	}
	s = strings.clone(string(cur.data[cur.pos:cur.pos + length]), allocator)
	cur.pos += length
	return s, true
}

snap_put_u64 :: proc(buf: ^[dynamic]u8, v: u64) {
	scratch: [8]u8
	_ = endian.put_u64(scratch[:], .Little, v)
	append(buf, ..scratch[:])
}

snap_put_string :: proc(buf: ^[dynamic]u8, s: string) {
	snap_put_u64(buf, u64(len(s)))
	append(buf, ..transmute([]u8)s)
}

snap_sorted_field_names :: proc(fields: map[string]Field_Value) -> []string {
	names := make([dynamic]string, 0, len(fields), context.temp_allocator)
	for name in fields {
		append(&names, name)
	}
	slice.sort(names[:])
	return names[:]
}

snap_sorted_value_field_names :: proc(fields: map[string]Value) -> []string {
	names := make([dynamic]string, 0, len(fields), context.temp_allocator)
	for name in fields {
		append(&names, name)
	}
	slice.sort(names[:])
	return names[:]
}
