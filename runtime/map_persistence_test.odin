package funpack_runtime

import "core:testing"

@(private = "file")
mp_cell :: proc(x, y: i64) -> Value {
	fields := make(map[string]Value)
	fields["x"] = x
	fields["y"] = y
	return Record_Value{type_name = "Cell", fields = fields}
}

@(private = "file")
mp_tile :: proc(case_name: string) -> Value {
	return Variant_Value{enum_type = "Tile", case_name = case_name}
}

@(private = "file")
mp_floor_version :: proc(pairs: ..Map_Entry) -> World_Version {
	entries := make([]Map_Entry, len(pairs))
	for p, i in pairs {
		entries[i] = p
	}
	row_fields := make(map[string]Field_Value)
	row_fields["tiles"] = Map_Value{entries = entries}
	rows := make([]Row, 1)
	rows[0] = Row{id = Id{raw = 1}, fields = row_fields}
	tables := make([]Version_Table, 1)
	tables[0] = Version_Table{thing = "Dungeon", singleton = true, rows = rows, next_id = 2}
	return World_Version{tick = 7, tables = tables}
}

@(test)
test_stored_map_round_trips_through_snapshot :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	committed := mp_floor_version(
		Map_Entry{key = mp_cell(0, 0), value = mp_tile("Wall")},
		Map_Entry{key = mp_cell(1, 0), value = mp_tile("Floor")},
		Map_Entry{key = mp_cell(2, 0), value = mp_tile("Wall")},
	)

	bare_program := Program{}
	bytes := serialize_snapshot(&bare_program, committed)
	restored, _, _, ok := deserialize_snapshot(bytes)
	if !testing.expect(t, ok) {
		return
	}
	testing.expect(t, world_versions_equal(committed, restored))

	saved := frame_digest(committed, nil)
	restored_digest := frame_digest(restored, nil)
	testing.expect_value(t, restored_digest.digest, saved.digest)

	restored_map := restored.tables[0].rows[0].fields["tiles"].(Map_Value)
	testing.expect_value(t, len(restored_map.entries), 3)
	hit := map_get_value(&Interp{allocator = context.temp_allocator}, restored_map, mp_cell(1, 0))
	hit_variant := hit.(Variant_Value)
	testing.expect(t, hit_variant.case_name == "Some")
	testing.expect(t, hit_variant.payload != nil)
	if hit_variant.payload != nil {
		tile := hit_variant.payload^.(Variant_Value)
		testing.expect(t, tile.enum_type == "Tile" && tile.case_name == "Floor")
	}
	miss := map_get_value(&Interp{allocator = context.temp_allocator}, restored_map, mp_cell(9, 9))
	miss_variant := miss.(Variant_Value)
	testing.expect(t, miss_variant.case_name == "None")
}

@(test)
test_stored_map_snapshot_codec_is_a_fixed_point :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	committed := mp_floor_version(
		Map_Entry{key = mp_cell(0, 0), value = mp_tile("Wall")},
		Map_Entry{key = mp_cell(1, 0), value = mp_tile("Floor")},
	)
	bare_program := Program{}
	first := serialize_snapshot(&bare_program, committed)
	restored, _, _, ok := deserialize_snapshot(first)
	if !testing.expect(t, ok) {
		return
	}
	second := serialize_snapshot(&bare_program, restored)
	testing.expect_value(t, len(second), len(first))
	for b, i in first {
		if i < len(second) {
			testing.expect_value(t, second[i], b)
		}
	}
}

@(test)
test_stored_map_commit_read_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	original := Map_Value {
		entries = {
			Map_Entry{key = mp_cell(0, 0), value = mp_tile("Wall")},
			Map_Entry{key = mp_cell(1, 0), value = mp_tile("Floor")},
		},
	}
	committed, ok := value_to_field_value(original, context.temp_allocator)
	testing.expect(t, ok)
	column, is_map := committed.(Map_Value)
	testing.expect(t, is_map)
	testing.expect_value(t, len(column.entries), 2)
	read_back := field_value_to_value(committed)
	testing.expect(t, values_equal(original, read_back))
}

@(test)
test_stored_map_digest_is_insertion_ordered :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	forward := mp_floor_version(
		Map_Entry{key = mp_cell(0, 0), value = mp_tile("Wall")},
		Map_Entry{key = mp_cell(1, 0), value = mp_tile("Floor")},
	)
	reversed := mp_floor_version(
		Map_Entry{key = mp_cell(1, 0), value = mp_tile("Floor")},
		Map_Entry{key = mp_cell(0, 0), value = mp_tile("Wall")},
	)
	forward_digest := frame_digest(forward, nil)
	reversed_digest := frame_digest(reversed, nil)
	testing.expect(t, forward_digest.digest != reversed_digest.digest)

	forward_again := mp_floor_version(
		Map_Entry{key = mp_cell(0, 0), value = mp_tile("Wall")},
		Map_Entry{key = mp_cell(1, 0), value = mp_tile("Floor")},
	)
	testing.expect_value(t, frame_digest(forward_again, nil).digest, forward_digest.digest)
}
