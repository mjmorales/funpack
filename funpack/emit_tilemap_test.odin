package funpack

import "core:strings"
import "core:testing"

emit_tilemaps_section :: proc(layers: []Baked_Tile_Layer) -> string {
	b := strings.builder_make(context.temp_allocator)
	emit_tilemaps(&b, layers)
	return strings.to_string(b)
}

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
	testing.expect_value(t, emit_tilemaps_section(nil), "[tilemaps 0]\n")
}

@(test)
test_tile_row_sub_records_frame_under_lead_line_reader :: proc(t: ^testing.T) {
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
	doc_text := strings.concatenate(
		{"funpack-artifact 19\n", emit_tilemaps_section(tile_layer_fixture())},
		context.temp_allocator,
	)
	doc, err := parse_artifact(doc_text)
	testing.expect_value(t, err, Artifact_Parse_Error.None)
	section, found := artifact_find_section(doc, "tilemaps")
	testing.expect(t, found)
	testing.expect_value(t, section.count, 1)
	testing.expect_value(t, len(section.body), 6)
}

@(test)
test_emit_tilemaps_deterministic :: proc(t: ^testing.T) {
	first := emit_tilemaps_section(tile_layer_fixture())
	second := emit_tilemaps_section(tile_layer_fixture())
	testing.expect(t, first == second)
}
