package funpack_runtime

import "core:testing"

TILEMAP_FIXTURE_ARTIFACT ::
	"funpack-artifact 19\n" +
	"[tilemaps 1]\n" +
	"tilemap terrain 16 4 3 0 206158430208 - 2\n" +
	"tile wall true 0 0\n" +
	"tile floor false 1 0\n" +
	"row 0 0 0 0\n" +
	"row 0 - 1 -\n" +
	"row 0 - 0 0\n"

fixture_layer :: proc() -> Tile_Layer {
	palette := make([]Tile_Def, 2, context.temp_allocator)
	palette[0] = Tile_Def{name = "wall", solid = true, cell_x = 0, cell_y = 0}
	palette[1] = Tile_Def{name = "floor", solid = false, cell_x = 1, cell_y = 0}
	cells := make([]int, 12, context.temp_allocator)
	copy(cells, []int{0, 0, 0, 0, 0, TILE_CELL_EMPTY, 1, TILE_CELL_EMPTY, 0, TILE_CELL_EMPTY, 0, 0})
	return Tile_Layer {
		name      = "terrain",
		cell_size = 16,
		cols      = 4,
		rows      = 3,
		top_left  = Vec2{x = to_fixed(0), y = to_fixed(48)},
		atlas     = "",
		palette   = palette,
		cells     = cells,
	}
}

dungeon_layer :: proc() -> Tile_Layer {
	palette := make([]Tile_Def, 1, context.temp_allocator)
	palette[0] = Tile_Def{name = "floor", solid = false, cell_x = 0, cell_y = 0}
	cells := make([]int, 16 * 9, context.temp_allocator)
	return Tile_Layer {
		name      = "terrain",
		cell_size = 16,
		cols      = 16,
		rows      = 9,
		top_left  = Vec2{x = to_fixed(0), y = to_fixed(144)},
		atlas     = "",
		palette   = palette,
		cells     = cells,
	}
}

@(test)
test_load_tilemaps_populated_decodes :: proc(t: ^testing.T) {
	program, err := load_program(TILEMAP_FIXTURE_ARTIFACT, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, len(program.tilemaps), 1)
	layer := program.tilemaps[0]
	testing.expect_value(t, layer.name, "terrain")
	testing.expect_value(t, layer.cell_size, 16)
	testing.expect_value(t, layer.cols, 4)
	testing.expect_value(t, layer.rows, 3)
	testing.expect_value(t, layer.top_left.x, to_fixed(0))
	testing.expect_value(t, layer.top_left.y, to_fixed(48))
	testing.expect_value(t, layer.atlas, "")
	testing.expect_value(t, len(layer.palette), 2)
	testing.expect_value(t, layer.palette[0], Tile_Def{name = "wall", solid = true, cell_x = 0, cell_y = 0})
	testing.expect_value(t, layer.palette[1], Tile_Def{name = "floor", solid = false, cell_x = 1, cell_y = 0})
	expected_cells := []int{0, 0, 0, 0, 0, TILE_CELL_EMPTY, 1, TILE_CELL_EMPTY, 0, TILE_CELL_EMPTY, 0, 0}
	testing.expect_value(t, len(layer.cells), len(expected_cells))
	for cell, i in expected_cells {
		testing.expect_value(t, layer.cells[i], cell)
	}
	testing.expect(t, tile_layers_equal(layer, fixture_layer()))
}

@(test)
test_load_tilemaps_empty_section_still_loads :: proc(t: ^testing.T) {
	program, err := load_program("funpack-artifact 19\n[tilemaps 0]\n", context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, len(program.tilemaps), 0)
}

@(test)
test_load_tilemaps_malformed_refused :: proc(t: ^testing.T) {
	malformed := [?]string {
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 16 4 3 0 0 2\ntile wall true 0 0\ntile floor false 1 0\nrow 0 0 0 0\nrow 0 0 0 0\nrow 0 0 0 0\n",
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 16 2 1 0 y - 1\ntile wall true 0 0\nrow 0 0\n",
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 0 2 1 0 0 - 1\ntile wall true 0 0\nrow 0 0\n",
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 16 0 1 0 0 - 1\ntile wall true 0 0\nrow\n",
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 16 2 x 0 0 - 1\ntile wall true 0 0\nrow 0 0\n",
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 1\ntile wall true 0 0\nrow 0 0\n",
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 16 2 2 0 0 - 1\ntile wall true 0 0\nrow 0 0\n",
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 - 1\ntile wall true 0 0\ntile floor false 1 0\nrow 0 0\n",
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 - 1\nrow 0 0\ntile wall true 0 0\n",
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 - 1\ntile wall yes 0 0\nrow 0 0\n",
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 - 1\ntile wall true\nrow 0 0\n",
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 - 1\ntile wall true x 0\nrow 0 0\n",
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 - 1\ntile wall true 0 -1\nrow 0 0\n",
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 - 1\ntile wall true 0 0\nrow 0\n",
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 - 1\ntile wall true 0 0\nrow 0 1\n",
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 - 1\ntile wall true 0 0\nrow 0 -2\n",
		"funpack-artifact 19\n[tilemaps 1]\ntilemap terrain 16 2 1 0 0 - 1\ntile wall true 0 0\nrow 0 z\n",
	}
	for artifact in malformed {
		_, err := load_program(artifact, context.temp_allocator)
		testing.expect_value(t, err, Artifact_Error.Bad_Field)
	}
}

@(test)
test_load_tilemaps_deterministic :: proc(t: ^testing.T) {
	first, err1 := load_program(TILEMAP_FIXTURE_ARTIFACT, context.temp_allocator)
	second, err2 := load_program(TILEMAP_FIXTURE_ARTIFACT, context.temp_allocator)
	testing.expect_value(t, err1, Artifact_Error.None)
	testing.expect_value(t, err2, Artifact_Error.None)
	testing.expect_value(t, len(first.tilemaps), len(second.tilemaps))
	for layer, i in first.tilemaps {
		testing.expect(t, tile_layers_equal(layer, second.tilemaps[i]))
	}
}

@(test)
test_tilemap_tile_at_exact :: proc(t: ^testing.T) {
	layer := fixture_layer()
	name, has := tilemap_tile_at(&layer, 0, 0)
	testing.expect(t, has)
	testing.expect_value(t, name, "wall")
	name, has = tilemap_tile_at(&layer, 2, 1)
	testing.expect(t, has)
	testing.expect_value(t, name, "floor")
	_, has = tilemap_tile_at(&layer, 1, 1)
	testing.expect(t, !has)
	_, has = tilemap_tile_at(&layer, -1, 0)
	testing.expect(t, !has)
	_, has = tilemap_tile_at(&layer, 4, 0)
	testing.expect(t, !has)
	_, has = tilemap_tile_at(&layer, 0, -1)
	testing.expect(t, !has)
	_, has = tilemap_tile_at(&layer, 0, 3)
	testing.expect(t, !has)
}

@(test)
test_tilemap_solid_at_exact :: proc(t: ^testing.T) {
	layer := fixture_layer()
	testing.expect(t, tilemap_solid_at(&layer, 0, 0))
	testing.expect(t, !tilemap_solid_at(&layer, 2, 1))
	testing.expect(t, !tilemap_solid_at(&layer, 1, 1))
	testing.expect(t, !tilemap_solid_at(&layer, 9, 9))
}

@(test)
test_tilemap_cell_of_exact :: proc(t: ^testing.T) {
	layer := fixture_layer()
	col, row := tilemap_cell_of(&layer, Vec2{x = to_fixed(8), y = to_fixed(40)})
	testing.expect_value(t, col, 0)
	testing.expect_value(t, row, 0)
	col, row = tilemap_cell_of(&layer, Vec2{x = to_fixed(0), y = to_fixed(48)})
	testing.expect_value(t, col, 0)
	testing.expect_value(t, row, 0)
	col, row = tilemap_cell_of(&layer, Vec2{x = to_fixed(16), y = to_fixed(32)})
	testing.expect_value(t, col, 1)
	testing.expect_value(t, row, 1)
	col, row = tilemap_cell_of(&layer, Vec2{x = to_fixed(63), y = to_fixed(1)})
	testing.expect_value(t, col, 3)
	testing.expect_value(t, row, 2)
	col, row = tilemap_cell_of(&layer, Vec2{x = to_fixed(-1), y = to_fixed(49)})
	testing.expect_value(t, col, -1)
	testing.expect_value(t, row, -1)
}

@(test)
test_tilemap_center_of_exact :: proc(t: ^testing.T) {
	layer := fixture_layer()
	center := tilemap_center_of(&layer, 0, 0)
	testing.expect_value(t, center.x, to_fixed(8))
	testing.expect_value(t, center.y, to_fixed(40))
	center = tilemap_center_of(&layer, 3, 2)
	testing.expect_value(t, center.x, to_fixed(56))
	testing.expect_value(t, center.y, to_fixed(8))
	center = tilemap_center_of(&layer, 4, 3)
	testing.expect_value(t, center.x, to_fixed(72))
	testing.expect_value(t, center.y, to_fixed(-8))
}

@(test)
test_tilemap_dungeon_grid_parity :: proc(t: ^testing.T) {
	layer := dungeon_layer()
	chest := tilemap_center_of(&layer, 13, 4)
	testing.expect_value(t, chest.x, to_fixed(216))
	testing.expect_value(t, chest.y, to_fixed(72))
	hero := tilemap_center_of(&layer, 2, 2)
	testing.expect_value(t, hero.x, to_fixed(40))
	testing.expect_value(t, hero.y, to_fixed(104))
	for row in 0 ..< layer.rows {
		for col in 0 ..< layer.cols {
			center := tilemap_center_of(&layer, i64(col), i64(row))
			back_col, back_row := tilemap_cell_of(&layer, center)
			testing.expect_value(t, back_col, i64(col))
			testing.expect_value(t, back_row, i64(row))
		}
	}
}

@(test)
test_tilemap_kernel_general_over_anchor :: proc(t: ^testing.T) {
	layer := fixture_layer()
	layer.top_left = Vec2{x = to_fixed(-32), y = to_fixed(16)}
	center := tilemap_center_of(&layer, 0, 0)
	testing.expect_value(t, center.x, to_fixed(-24))
	testing.expect_value(t, center.y, to_fixed(8))
	col, row := tilemap_cell_of(&layer, center)
	testing.expect_value(t, col, 0)
	testing.expect_value(t, row, 0)
	col, row = tilemap_cell_of(&layer, Vec2{x = to_fixed(-33), y = to_fixed(17)})
	testing.expect_value(t, col, -1)
	testing.expect_value(t, row, -1)
}

@(test)
test_floor_div_rounds_toward_negative_infinity :: proc(t: ^testing.T) {
	testing.expect_value(t, floor_div(i64(6), 3), 2)
	testing.expect_value(t, floor_div(i64(7), 3), 2)
	testing.expect_value(t, floor_div(i64(-6), 3), -2)
	testing.expect_value(t, floor_div(i64(-7), 3), -3)
	testing.expect_value(t, floor_div(i64(7), -3), -3)
	testing.expect_value(t, floor_div(i64(-7), -3), 2)
}

tilemap_test_interp :: proc(program: ^Program, version: ^World_Version) -> Interp {
	return new_interp(program, version, nil, empty(), tilemap_time_resource(), context.temp_allocator)
}

tilemap_time_resource :: proc() -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["dt"] = fixed_div(to_fixed(1), to_fixed(60))
	return Record_Value{type_name = "Time", fields = fields}
}

tilemap_handle_value :: proc(name: string) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["name"] = String_Value{text = name}
	return Record_Value{type_name = "TilemapHandle", fields = fields}
}

tilemap_cell_record :: proc(x, y: i64) -> Record_Value {
	fields := make(map[string]Value, context.temp_allocator)
	fields["x"] = x
	fields["y"] = y
	return Record_Value{type_name = "Cell", fields = fields}
}

eval_tilemap_query :: proc(
	interp: ^Interp,
	method: string,
	handle: Record_Value,
	arg: Value,
) -> (
	result: Value,
	ok: bool,
) {
	recv := Node{kind = .Name, fields = tilemap_node_fields("m")}
	field := Node{kind = .Field, fields = tilemap_node_fields(method), children = tilemap_node_children(recv)}
	arg_node := Node{kind = .Name, fields = tilemap_node_fields("c")}
	call := Node {
		kind     = .Call,
		children = tilemap_node_children(field, arg_node),
	}
	env := Env {
		names = make(map[string]Value, context.temp_allocator),
	}
	env.names["m"] = handle
	env.names["c"] = arg
	return eval(interp, &call, &env)
}

tilemap_node_fields :: proc(tokens: ..string) -> []string {
	out := make([]string, len(tokens), context.temp_allocator)
	copy(out, tokens)
	return out
}

tilemap_node_children :: proc(nodes: ..Node) -> []Node {
	out := make([]Node, len(nodes), context.temp_allocator)
	copy(out, nodes)
	return out
}

@(test)
test_tilemap_method_dispatch :: proc(t: ^testing.T) {
	layers := make([]Tile_Layer, 1, context.temp_allocator)
	layers[0] = fixture_layer()
	program := Program{}
	version := World_Version {
		tilemaps = layers,
	}
	interp := tilemap_test_interp(&program, &version)
	handle := tilemap_handle_value("terrain")

	result, ok := eval_tilemap_query(&interp, "tile_at", handle, tilemap_cell_record(0, 0))
	testing.expect(t, ok)
	some := result.(Variant_Value)
	testing.expect_value(t, some.enum_type, "Option")
	testing.expect_value(t, some.case_name, "Some")
	payload := some.payload^.(String_Value)
	testing.expect_value(t, payload.text, "wall")

	result, ok = eval_tilemap_query(&interp, "tile_at", handle, tilemap_cell_record(1, 1))
	testing.expect(t, ok)
	none := result.(Variant_Value)
	testing.expect_value(t, none.case_name, "None")

	result, ok = eval_tilemap_query(&interp, "solid_at", handle, tilemap_cell_record(0, 0))
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), true)
	result, ok = eval_tilemap_query(&interp, "solid_at", handle, tilemap_cell_record(2, 1))
	testing.expect(t, ok)
	testing.expect_value(t, result.(bool), false)

	result, ok = eval_tilemap_query(&interp, "cell_of", handle, Vec2{x = to_fixed(8), y = to_fixed(40)})
	testing.expect(t, ok)
	cell := result.(Record_Value)
	testing.expect_value(t, cell.type_name, "Cell")
	testing.expect_value(t, cell.fields["x"].(i64), 0)
	testing.expect_value(t, cell.fields["y"].(i64), 0)

	result, ok = eval_tilemap_query(&interp, "center_of", handle, tilemap_cell_record(3, 2))
	testing.expect(t, ok)
	center := result.(Vec2)
	testing.expect_value(t, center.x, to_fixed(56))
	testing.expect_value(t, center.y, to_fixed(8))
}

@(test)
test_tilemap_method_dispatch_fails_closed :: proc(t: ^testing.T) {
	layers := make([]Tile_Layer, 1, context.temp_allocator)
	layers[0] = fixture_layer()
	program := Program{}
	version := World_Version {
		tilemaps = layers,
	}
	interp := tilemap_test_interp(&program, &version)

	_, ok := eval_tilemap_query(&interp, "tile_at", tilemap_handle_value("nowhere"), tilemap_cell_record(0, 0))
	testing.expect(t, !ok)
	_, ok = eval_tilemap_query(&interp, "tile_at", tilemap_handle_value("terrain"), i64(3))
	testing.expect(t, !ok)
	_, ok = eval_tilemap_query(&interp, "cell_of", tilemap_handle_value("terrain"), tilemap_cell_record(0, 0))
	testing.expect(t, !ok)
	_, ok = eval_tilemap_query(&interp, "warp_to", tilemap_handle_value("terrain"), tilemap_cell_record(0, 0))
	testing.expect(t, !ok)
}

@(test)
test_render_emits_one_batched_tilemap_command :: proc(t: ^testing.T) {
	layers := make([]Tile_Layer, 1, context.temp_allocator)
	layers[0] = fixture_layer()
	program := Program{}
	version := World_Version {
		tilemaps = layers,
	}
	draw := render_version(&program, version, empty(), tilemap_time_resource(), context.temp_allocator)
	testing.expect_value(t, len(draw.cmds), 1)
	cmd, is_tilemap := draw.cmds[0].(Draw_Tilemap)
	testing.expect(t, is_tilemap)
	testing.expect(t, tile_layers_equal(cmd.layer, fixture_layer()))
	testing.expect_value(t, len(cmd.palette_textures), 2)
	for tex in cmd.palette_textures {
		testing.expect(t, !tex.resolved)
	}
	again := render_version(&program, version, empty(), tilemap_time_resource(), context.temp_allocator)
	testing.expect(t, draw_cmd_equal(draw.cmds[0], again.cmds[0]))
}

@(test)
test_render_layer_free_program_emits_no_tilemap_command :: proc(t: ^testing.T) {
	program := Program{}
	draw := render_version(&program, World_Version{}, empty(), tilemap_time_resource(), context.temp_allocator)
	testing.expect_value(t, len(draw.cmds), 0)
}

@(test)
test_tilemap_digest_deterministic_and_content_sensitive :: proc(t: ^testing.T) {
	testing.expect_value(t, u8(Cmd_Tag.Tilemap), 7)

	cmds := make([]Draw_Cmd, 1, context.temp_allocator)
	cmds[0] = Draw_Tilemap{layer = fixture_layer()}
	draw := Draw_List{cmds = cmds}
	first := frame_bytes(World_Version{}, draw, context.temp_allocator)
	second := frame_bytes(World_Version{}, draw, context.temp_allocator)
	testing.expect(t, len(first) > 0)
	testing.expect_value(t, len(first), len(second))
	for b, i in first {
		testing.expect_value(t, second[i], b)
	}

	flipped_layer := fixture_layer()
	flipped_cells := make([]int, len(flipped_layer.cells), context.temp_allocator)
	copy(flipped_cells, flipped_layer.cells)
	flipped_cells[5] = 1
	flipped_layer.cells = flipped_cells
	flipped_cmds := make([]Draw_Cmd, 1, context.temp_allocator)
	flipped_cmds[0] = Draw_Tilemap{layer = flipped_layer}
	flipped := frame_bytes(World_Version{}, Draw_List{cmds = flipped_cmds}, context.temp_allocator)
	identical := len(flipped) == len(first)
	if identical {
		for b, i in first {
			if flipped[i] != b {
				identical = false
				break
			}
		}
	}
	testing.expect(t, !identical)
}

texture_atlas :: proc() -> Asset_Set {
	regions := make([]Asset_Region, 4, context.temp_allocator)
	regions[0] = Asset_Region{name = "floor", px_x = 0, px_y = 0, px_w = 16, px_h = 16}
	regions[1] = Asset_Region{name = "wall", px_x = 16, px_y = 0, px_w = 16, px_h = 16}
	regions[2] = Asset_Region{name = "water", px_x = 32, px_y = 0, px_w = 16, px_h = 16}
	regions[3] = Asset_Region{name = "rubble", px_x = 48, px_y = 0, px_w = 16, px_h = 16}
	images := make([]Asset_Image, 1, context.temp_allocator)
	images[0] = Asset_Image{hash = "sha256:tiles", width = 64, height = 32, pixels = nil}
	atlases := make([]Asset_Atlas, 1, context.temp_allocator)
	atlases[0] = Asset_Atlas{name = "dungeon_atlas", image_hash = "sha256:tiles", regions = regions}
	return Asset_Set{images = images, atlases = atlases}
}

textured_layer :: proc() -> Tile_Layer {
	palette := make([]Tile_Def, 4, context.temp_allocator)
	palette[0] = Tile_Def{name = "floor", solid = false, cell_x = 0, cell_y = 0}
	palette[1] = Tile_Def{name = "wall", solid = true, cell_x = 1, cell_y = 0}
	palette[2] = Tile_Def{name = "water", solid = false, cell_x = 2, cell_y = 0}
	palette[3] = Tile_Def{name = "rubble", solid = true, cell_x = 3, cell_y = 0}
	cells := make([]int, 4, context.temp_allocator)
	copy(cells, []int{0, 1, 2, 3})
	return Tile_Layer {
		name      = "terrain",
		cell_size = 16,
		cols      = 2,
		rows      = 2,
		top_left  = Vec2{x = to_fixed(0), y = to_fixed(32)},
		atlas     = "dungeon_atlas",
		palette   = palette,
		cells     = cells,
	}
}

@(test)
test_tilemap_textures_resolve_palette_to_atlas_cell_rects :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	layers := make([]Tile_Layer, 1, context.temp_allocator)
	layers[0] = textured_layer()
	program := Program{assets = texture_atlas()}
	version := World_Version{tilemaps = layers}
	draw := render_version(&program, version, empty(), tilemap_time_resource(), context.temp_allocator)

	testing.expect_value(t, len(draw.cmds), 1)
	cmd := draw.cmds[0].(Draw_Tilemap)
	testing.expect_value(t, len(cmd.palette_textures), 4)

	expected := [4][4]int{{0, 0, 16, 16}, {16, 0, 16, 16}, {32, 0, 16, 16}, {48, 0, 16, 16}}
	for tex, i in cmd.palette_textures {
		testing.expect(t, tex.resolved)
		testing.expect_value(t, tex.image_hash, "sha256:tiles")
		testing.expect_value(t, tex.px_x, expected[i][0])
		testing.expect_value(t, tex.px_y, expected[i][1])
		testing.expect_value(t, tex.px_w, expected[i][2])
		testing.expect_value(t, tex.px_h, expected[i][3])
	}
}

@(test)
test_tilemap_texture_resolution_is_in_the_digest :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	program := Program{assets = texture_atlas()}

	layers := make([]Tile_Layer, 1, context.temp_allocator)
	layers[0] = textured_layer()
	version := World_Version{tilemaps = layers}
	draw := render_version(&program, version, empty(), tilemap_time_resource(), context.temp_allocator)
	first := frame_bytes(World_Version{}, draw, context.temp_allocator)
	second := frame_bytes(World_Version{}, draw, context.temp_allocator)
	testing.expect_value(t, len(first), len(second))
	for b, i in first {
		testing.expect_value(t, second[i], b)
	}

	moved_layers := make([]Tile_Layer, 1, context.temp_allocator)
	moved := textured_layer()
	moved_palette := make([]Tile_Def, len(moved.palette), context.temp_allocator)
	copy(moved_palette, moved.palette)
	moved_palette[3].cell_y = 1
	moved.palette = moved_palette
	moved_layers[0] = moved
	moved_draw := render_version(&program, World_Version{tilemaps = moved_layers}, empty(), tilemap_time_resource(), context.temp_allocator)
	moved_bytes := frame_bytes(World_Version{}, moved_draw, context.temp_allocator)
	identical := len(moved_bytes) == len(first)
	if identical {
		for b, i in first {
			if moved_bytes[i] != b {
				identical = false
				break
			}
		}
	}
	testing.expect(t, !identical)
}

@(test)
test_tilemap_texture_resolution_fail_closed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	atlasless_layers := make([]Tile_Layer, 1, context.temp_allocator)
	atlasless_layers[0] = fixture_layer()
	atlasless_program := Program{assets = texture_atlas()}
	draw := render_version(&atlasless_program, World_Version{tilemaps = atlasless_layers}, empty(), tilemap_time_resource(), context.temp_allocator)
	cmd := draw.cmds[0].(Draw_Tilemap)
	testing.expect_value(t, len(cmd.palette_textures), 2)
	for tex in cmd.palette_textures {
		testing.expect(t, !tex.resolved)
		testing.expect_value(t, tex.image_hash, "")
		testing.expect_value(t, tex.px_w, 0)
	}

	unknown_layers := make([]Tile_Layer, 1, context.temp_allocator)
	unknown := textured_layer()
	unknown.atlas = "no_such_atlas"
	unknown_layers[0] = unknown
	unknown_draw := render_version(&atlasless_program, World_Version{tilemaps = unknown_layers}, empty(), tilemap_time_resource(), context.temp_allocator)
	unknown_cmd := unknown_draw.cmds[0].(Draw_Tilemap)
	for tex in unknown_cmd.palette_textures {
		testing.expect(t, !tex.resolved)
		testing.expect_value(t, tex.px_w, 0)
	}
}

@(test)
test_atlas_cell_dims_zero_region_atlas_fails_closed :: proc(t: ^testing.T) {
	empty_atlas := Asset_Atlas{name = "empty", image_hash = "sha256:x", regions = nil}
	_, _, ok := atlas_cell_dims(&empty_atlas)
	testing.expect(t, !ok)
}
