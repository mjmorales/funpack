// Golden persistence fixture for a STORED engine.map Map[K, V] field (decision
// 2026-06-25-engine-map-insertion-ordered; the friction repro `data Floor { tiles:
// Map[Cell, Tile] }`). Proves the determinism contract end-to-end: a committed Map
// column round-trips through the snapshot codec bit-identically, digests transparently
// across save/restore, and its INSERTION ORDER is observable in the digest (two maps
// with the same entries built in a different order digest differently). Hand-builds the
// committed columns (the test_save_snapshot_round_trips_nested_payload_variant mold) so
// the fixture needs no compiler artifact.
package funpack_runtime

import "core:testing"

// mp_cell builds a Cell{x, y} record value — the engine.grid record key a dungeon
// floor maps tiles by (the grid_cells structural-record discipline).
@(private = "file")
mp_cell :: proc(x, y: i64) -> Value {
	fields := make(map[string]Value)
	fields["x"] = x
	fields["y"] = y
	return Record_Value{type_name = "Cell", fields = fields}
}

// mp_tile builds a Tile::<case> unit-variant value — the floor's per-cell terrain.
@(private = "file")
mp_tile :: proc(case_name: string) -> Value {
	return Variant_Value{enum_type = "Tile", case_name = case_name}
}

// mp_floor_version wraps a Map[Cell, Tile] as the `tiles` column of one Dungeon row
// in a committed World_Version at tick 7 — the stored-keyed-state shape the digest
// folds and the snapshot persists. The pairs land in the given order (insertion
// order is the value's canonical order).
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
	// AC: a committed Map[Cell, Tile] column saves and restores bit-identically AND
	// digests transparently — the store->save->restore round-trip a §24 quickload of a
	// dungeon floor relies on. world_versions_equal compares the Map column positionally
	// (values_equal), so a codec that drops or reorders entries fails here.
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

	// The restored Map digests identically to the saved one — a Restore swap is
	// digest-transparent (the determinism contract over the persisted form).
	saved := frame_digest(committed, nil)
	restored_digest := frame_digest(restored, nil)
	testing.expect_value(t, restored_digest.digest, saved.digest)

	// Read the restored column back explicitly: the keyed lookup survives the round
	// trip — Cell{1,0} reads Tile::Floor, an unstored cell reads None.
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
	// AC: serialize ∘ deserialize ∘ serialize == serialize over a Map column — the
	// content-hash-pinned codec is a fixed point, so a Map-bearing slot written on one
	// machine restores byte-identically on another (cross-machine reproducibility).
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
	// AC: the TICK-COMMIT boundary — a behavior's Map result lowers into a committed
	// column (value_to_field_value, deep-cloned into the commit allocator) and reads
	// back as the same interp Map (field_value_to_value). This is the store half of
	// store->tick->save the fixtures above pick up from; it proves the commit path
	// owns its entries independent of the eval arena (clone_map_value) and the value
	// survives the boundary equal.
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
	// AC: insertion order is OBSERVABLE in the frame digest — two Dungeon floors with
	// the SAME (Cell, Tile) entries built in a DIFFERENT insertion order fold to
	// DIFFERENT digests (the determinism contract: a differently-built map is a
	// different committed state). This is what forbids a non-deterministic hash-map
	// iteration order from silently corrupting replay.
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

	// The same insertion order folds identically — a digest is a function of the
	// committed value alone, so two folds of the same floor are bit-identical.
	forward_again := mp_floor_version(
		Map_Entry{key = mp_cell(0, 0), value = mp_tile("Wall")},
		Map_Entry{key = mp_cell(1, 0), value = mp_tile("Floor")},
	)
	testing.expect_value(t, frame_digest(forward_again, nil).digest, forward_digest.digest)
}
