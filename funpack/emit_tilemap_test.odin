// The §18 §3 tile-layer artifact carry (schema v17, docs/artifact-format.md
// §17): the [tilemaps] section — per layer a `tilemap NAME CELL_SIZE COLS ROWS
// ANCHOR_X ANCHOR_Y ATLAS PALETTE_COUNT` lead line (the anchor is the grid's
// top-left world corner as raw Q32.32 Fixed, the v12 authoritative grid→world
// mapping datum; ATLAS is the layer's tileset atlas handle name, the §19
// textured-render link, v17), `tile NAME SOLID CELL_X CELL_Y` palette sub-records
// (v17 carries the atlas-cell coordinate beside the §18 §2 collision verdict), and
// ROWS `row …` cell lines — and the byte disciplines the carry rides on: a
// layer-less project emits the constant `[tilemaps 0]` tail (every section emits
// its header, §3), and the `tile`/`row` sub-record keywords frame under the funpack
// reader's lead-line discipline so every section count still reconciles. The
// emit-side reader (parse_artifact) is the round-trip proof; the loader-side decode
// is the runtime loader's (artifact_load.odin).
package funpack

import "core:strings"
import "core:testing"

// emit_tilemaps_section renders one layer set's [tilemaps] section bytes so
// each fixture pins the exact emitted lines without a full Emit_Input.
emit_tilemaps_section :: proc(layers: []Baked_Tile_Layer) -> string {
	b := strings.builder_make(context.temp_allocator)
	emit_tilemaps(&b, layers)
	return strings.to_string(b)
}

// tile_layer_fixture is the hand-built 4×3 layer the emission fixtures pin:
// two palette entries with their v17 atlas-cell coordinates, the three cell
// classes (tile, empty/marker, tile), a NONZERO v12 anchor — the grid's top-left
// at world (32, 48), i.e. a level whose bounds do not start at the origin, the
// exact shape the anchor carry exists for — and the layer's v17 atlas handle
// name, the §19 textured-render link.
tile_layer_fixture :: proc() -> []Baked_Tile_Layer {
	palette := make([]Baked_Tile, 2, context.temp_allocator)
	palette[0] = Baked_Tile{name = "wall", solid = true, cell_x = 1, cell_y = 0}
	palette[1] = Baked_Tile{name = "floor", solid = false, cell_x = 0, cell_y = 0}
	cells := make([]int, 12, context.temp_allocator)
	copy(cells, []int{
		0, 0, 0, 0,
		0, TILE_LAYER_EMPTY_CELL, 1, TILE_LAYER_EMPTY_CELL,
		0, TILE_LAYER_EMPTY_CELL, 0, 0,
	})
	layers := make([]Baked_Tile_Layer, 1, context.temp_allocator)
	layers[0] = Baked_Tile_Layer {
		name      = "terrain",
		cell_size = 16,
		cols      = 4,
		rows      = 3,
		anchor_x  = to_fixed(32),
		anchor_y  = to_fixed(48),
		atlas     = "terrain_atlas",
		palette   = palette,
		cells     = cells,
	}
	return layers
}

@(test)
test_emit_tilemaps_record_bytes :: proc(t: ^testing.T) {
	// AC (artifact carries the layer): the v17 record shape byte-exact — the
	// lead line's dimensions/cell-size, the anchor as raw Q32.32 decimal
	// (32·2^32 = 137438953472, 48·2^32 = 206158430208), the layer ATLAS handle
	// name, the palette count, the `tile NAME SOLID CELL_X CELL_Y` palette lines in
	// legend order (each carrying its v17 atlas-cell coordinate), and the row-major
	// `row` lines with `-` for tile-less cells (the golden-emission discipline).
	section := emit_tilemaps_section(tile_layer_fixture())
	expected :=
		"[tilemaps 1]\n" +
		"tilemap terrain 16 4 3 137438953472 206158430208 terrain_atlas 2\n" +
		"tile wall true 1 0\n" +
		"tile floor false 0 0\n" +
		"row 0 0 0 0\n" +
		"row 0 - 1 -\n" +
		"row 0 - 0 0\n"
	testing.expect_value(t, section, expected)
}

@(test)
test_emit_tilemaps_empty_section_for_layer_free_input :: proc(t: ^testing.T) {
	// AC (constant tail for layer-less projects): no layers emit the bare
	// `[tilemaps 0]` header — every section emits its header even at N = 0
	// (§3), so a reader always sees the fixed section run. Every committed
	// game artifact moves by the stamp plus exactly this line.
	testing.expect_value(t, emit_tilemaps_section(nil), "[tilemaps 0]\n")
}

@(test)
test_tile_row_sub_records_frame_under_lead_line_reader :: proc(t: ^testing.T) {
	// AC (reader discipline): `tile` and `row` are sub-record keywords (§2.1),
	// so a [tilemaps] section carrying palette and cell lines still reconciles
	// its declared top-level count under the funpack reader — the same
	// lead-line discipline every other sub-record frames by.
	testing.expect(t, is_sub_record_line("tile wall true 1 0"))
	testing.expect(t, is_sub_record_line("row 0 - 1 -"))
	doc_text :=
		"funpack-artifact 19\n" +
		"[tilemaps 2]\n" +
		"tilemap terrain 16 2 1 0 68719476736 terrain_atlas 1\n" +
		"tile wall true 1 0\n" +
		"row 0 0\n" +
		"tilemap canopy 16 2 1 0 68719476736 canopy_atlas 1\n" +
		"tile leaf false 0 0\n" +
		"row - 0\n"
	doc, err := parse_artifact(doc_text)
	testing.expect_value(t, err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)
	section, found := artifact_find_section(doc, "tilemaps")
	testing.expect(t, found)
	testing.expect_value(t, section.count, 2)
}

@(test)
test_emit_tilemaps_round_trips_through_reader :: proc(t: ^testing.T) {
	// AC (emit-side round trip): the freshly-emitted section parses back
	// through the funpack reader inside a v17 document — the declared count
	// reconciles against the lead-line discipline, so the bytes the runtime
	// story will decode are well-formed by construction.
	doc_text := strings.concatenate(
		{"funpack-artifact 19\n", emit_tilemaps_section(tile_layer_fixture())},
		context.temp_allocator,
	)
	doc, err := parse_artifact(doc_text)
	testing.expect_value(t, err, Artifact_Parse_Error.None)
	section, found := artifact_find_section(doc, "tilemaps")
	testing.expect(t, found)
	testing.expect_value(t, section.count, 1)
	// One lead line + 2 palette + 3 row lines.
	testing.expect_value(t, len(section.body), 6)
}

@(test)
test_emit_tilemaps_deterministic :: proc(t: ^testing.T) {
	// §29 determinism: two renders of the same layer set are byte-identical —
	// every walk is slice-order, no map reaches the emission.
	first := emit_tilemaps_section(tile_layer_fixture())
	second := emit_tilemaps_section(tile_layer_fixture())
	testing.expect(t, first == second)
}
