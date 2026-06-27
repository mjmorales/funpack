package funpack_runtime

import "core:testing"

@(private = "file")
tc_layer :: proc(
	name: string,
	cols, rows: int,
	palette: []Tile_Def,
	cells: []int,
	allocator := context.allocator,
) -> Tile_Layer {
	pal := make([]Tile_Def, len(palette), allocator)
	copy(pal, palette)
	cs := make([]int, len(cells), allocator)
	copy(cs, cells)
	return Tile_Layer {
		name = name,
		cell_size = 16,
		cols = cols,
		rows = rows,
		top_left = Vec2{x = to_fixed(0), y = to_fixed(i64(rows) * 16)},
		palette = pal,
		cells = cs,
	}
}

@(test)
test_reload_tile :: proc(t: ^testing.T) {
	a := context.temp_allocator

	wall_floor := []Tile_Def{{name = "wall", solid = true}, {name = "floor", solid = false}}

	{
		old_bake := make([]Tile_Layer, 1, a)
		old_bake[0] = tc_layer("terrain", 3, 1, wall_floor, []int{0, 0, 0}, a)
		live := make([]Tile_Layer, 1, a)
		live[0] = tc_layer("terrain", 3, 1, wall_floor, []int{0, 1, 0}, a)
		new_bake := make([]Tile_Layer, 1, a)
		new_bake[0] = tc_layer("terrain", 3, 1, wall_floor, []int{0, 0, 0}, a)

		delta := tile_carry_delta(old_bake, live, a)
		testing.expect_value(t, len(delta.edits), 1)
		testing.expect_value(t, delta.edits[0].layer_name, "terrain")
		testing.expect_value(t, delta.edits[0].col, 1)
		testing.expect_value(t, delta.edits[0].row, 0)
		testing.expect_value(t, delta.edits[0].tile_name, "floor")

		carried := tile_carry_apply(delta, new_bake, a)
		ver := World_Version {
			tilemaps = carried,
		}
		layer := version_tilemap(&ver, "terrain")
		testing.expect(t, layer != nil)
		testing.expect_value(t, tilemap_solid_at(layer, 1, 0), false)
		name, has := tilemap_tile_at(layer, 1, 0)
		testing.expect(t, has)
		testing.expect_value(t, name, "floor")
		testing.expect_value(t, tilemap_solid_at(layer, 0, 0), true)
		testing.expect_value(t, tilemap_solid_at(layer, 2, 0), true)
		testing.expect(t, raw_data(carried[0].cells) != raw_data(new_bake[0].cells))
	}

	{
		old_bake := make([]Tile_Layer, 1, a)
		old_bake[0] = tc_layer("terrain", 3, 1, wall_floor, []int{0, 0, 0}, a)
		live := make([]Tile_Layer, 1, a)
		live[0] = tc_layer("terrain", 3, 1, wall_floor, []int{0, 0, 1}, a)
		new_bake := make([]Tile_Layer, 1, a)
		new_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a)

		delta := tile_carry_delta(old_bake, live, a)
		testing.expect_value(t, len(delta.edits), 1)
		testing.expect_value(t, delta.edits[0].col, 2)

		carried := tile_carry_apply(delta, new_bake, a)
		testing.expect(t, raw_data(carried[0].cells) == raw_data(new_bake[0].cells))
		ver := World_Version {
			tilemaps = carried,
		}
		layer := version_tilemap(&ver, "terrain")
		testing.expect_value(t, layer.cols, 2)
		testing.expect_value(t, tilemap_solid_at(layer, 0, 0), true)
		testing.expect_value(t, tilemap_solid_at(layer, 1, 0), true)
	}

	{
		with_water := []Tile_Def {
			{name = "wall", solid = true},
			{name = "floor", solid = false},
			{name = "water", solid = false},
		}
		old_bake := make([]Tile_Layer, 1, a)
		old_bake[0] = tc_layer("terrain", 2, 1, with_water, []int{0, 0}, a)
		live := make([]Tile_Layer, 1, a)
		live[0] = tc_layer("terrain", 2, 1, with_water, []int{2, 0}, a)
		new_bake := make([]Tile_Layer, 1, a)
		new_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a)

		delta := tile_carry_delta(old_bake, live, a)
		testing.expect_value(t, len(delta.edits), 1)
		testing.expect_value(t, delta.edits[0].tile_name, "water")

		carried := tile_carry_apply(delta, new_bake, a)
		testing.expect(t, raw_data(carried[0].cells) == raw_data(new_bake[0].cells))
		ver := World_Version {
			tilemaps = carried,
		}
		layer := version_tilemap(&ver, "terrain")
		testing.expect_value(t, tilemap_solid_at(layer, 0, 0), true)
	}

	{
		old_bake := make([]Tile_Layer, 2, a)
		old_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a)
		old_bake[1] = tc_layer("fog", 2, 1, wall_floor, []int{0, 0}, a)
		live := make([]Tile_Layer, 2, a)
		live[0] = tc_layer("terrain", 2, 1, wall_floor, []int{1, 0}, a)
		live[1] = tc_layer("fog", 2, 1, wall_floor, []int{1, 0}, a)
		new_bake := make([]Tile_Layer, 1, a)
		new_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a)

		delta := tile_carry_delta(old_bake, live, a)
		testing.expect_value(t, len(delta.edits), 2)
		testing.expect_value(t, delta.edits[0].layer_name, "terrain")
		testing.expect_value(t, delta.edits[1].layer_name, "fog")

		carried := tile_carry_apply(delta, new_bake, a)
		testing.expect_value(t, len(carried), 1)
		ver := World_Version {
			tilemaps = carried,
		}
		layer := version_tilemap(&ver, "terrain")
		testing.expect_value(t, tilemap_solid_at(layer, 0, 0), false)
		testing.expect(t, version_tilemap(&ver, "fog") == nil)
	}

	{
		old_bake := make([]Tile_Layer, 1, a)
		old_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a)
		live := make([]Tile_Layer, 1, a)
		live[0] = tc_layer("terrain", 2, 1, wall_floor, []int{1, 0}, a)
		new_bake := make([]Tile_Layer, 1, a)
		new_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 1}, a)

		delta := tile_carry_delta(old_bake, live, a)
		testing.expect_value(t, len(delta.edits), 1)
		testing.expect_value(t, delta.edits[0].col, 0)

		carried := tile_carry_apply(delta, new_bake, a)
		ver := World_Version {
			tilemaps = carried,
		}
		layer := version_tilemap(&ver, "terrain")
		testing.expect_value(t, tilemap_solid_at(layer, 0, 0), false)
		testing.expect_value(t, tilemap_solid_at(layer, 1, 0), false)
	}

	{
		old_bake := make([]Tile_Layer, 1, a)
		old_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a)
		live := make([]Tile_Layer, 1, a)
		live[0] = tc_layer("terrain", 2, 1, wall_floor, []int{1, 0}, a)
		new_bake := make([]Tile_Layer, 1, a)
		new_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a)

		delta := tile_carry_delta(old_bake, live, a)
		carried := tile_carry_apply(delta, new_bake, a)
		ver := World_Version {
			tilemaps = carried,
		}
		layer := version_tilemap(&ver, "terrain")
		testing.expect_value(t, tilemap_solid_at(layer, 0, 0), false)
	}

	{
		old_bake := make([]Tile_Layer, 1, a)
		old_bake[0] = tc_layer("terrain", 2, 2, wall_floor, []int{0, 1, 1, 0}, a)
		live := make([]Tile_Layer, 1, a)
		live[0] = tc_layer("terrain", 2, 2, wall_floor, []int{0, 1, 1, 0}, a)
		new_bake := make([]Tile_Layer, 1, a)
		new_bake[0] = tc_layer("terrain", 2, 2, wall_floor, []int{1, 1, 0, 0}, a)

		delta := tile_carry_delta(old_bake, live, a)
		testing.expect_value(t, len(delta.edits), 0)

		carried := tile_carry_apply(delta, new_bake, a)
		testing.expect(t, raw_data(carried) == raw_data(new_bake))
		testing.expect(t, tile_layers_equal(carried[0], new_bake[0]))
	}

	{
		old_bake := make([]Tile_Layer, 1, a)
		old_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a)
		live := make([]Tile_Layer, 1, a)
		live[0] = tc_layer("terrain", 2, 1, wall_floor, []int{1, 0}, a)
		new_program := Program {
			tilemaps = make([]Tile_Layer, 1, a),
		}
		new_program.tilemaps[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a)

		world := World_Version {
			tick     = 7,
			tilemaps = live,
		}
		empty_set := Migration_Set{}
		carry := tile_carry_delta(old_bake, world.tilemaps, a)
		migrated, refusal := migrate_world_version(empty_set, world, &new_program, carry, a)
		testing.expect_value(t, refusal.kind, Migrate_Refusal_Kind.None)
		testing.expect_value(t, migrated.tick, 7)
		layer := version_tilemap(&migrated, "terrain")
		testing.expect(t, layer != nil)
		testing.expect_value(t, tilemap_solid_at(layer, 0, 0), false)
		testing.expect_value(t, tilemap_solid_at(layer, 1, 0), true)
	}
}

@(test)
test_reload_tile_multi_edit_order :: proc(t: ^testing.T) {
	a := context.temp_allocator
	wall_floor := []Tile_Def{{name = "wall", solid = true}, {name = "floor", solid = false}}

	old_bake := make([]Tile_Layer, 1, a)
	old_bake[0] = tc_layer("terrain", 2, 2, wall_floor, []int{0, 0, 0, 0}, a)
	live := make([]Tile_Layer, 1, a)
	live[0] = tc_layer("terrain", 2, 2, wall_floor, []int{0, 1, 1, 0}, a)

	delta := tile_carry_delta(old_bake, live, a)
	testing.expect_value(t, len(delta.edits), 2)
	testing.expect_value(t, delta.edits[0].col, 1)
	testing.expect_value(t, delta.edits[0].row, 0)
	testing.expect_value(t, delta.edits[1].col, 0)
	testing.expect_value(t, delta.edits[1].row, 1)
}

@(test)
test_reload_tile_palette_reshuffle :: proc(t: ^testing.T) {
	a := context.temp_allocator
	old_pal := []Tile_Def{{name = "wall", solid = true}, {name = "floor", solid = false}}
	new_pal := []Tile_Def{{name = "floor", solid = false}, {name = "wall", solid = true}}

	old_bake := make([]Tile_Layer, 1, a)
	old_bake[0] = tc_layer("terrain", 2, 1, old_pal, []int{0, 0}, a)
	live := make([]Tile_Layer, 1, a)
	live[0] = tc_layer("terrain", 2, 1, old_pal, []int{1, 0}, a)
	new_bake := make([]Tile_Layer, 1, a)
	new_bake[0] = tc_layer("terrain", 2, 1, new_pal, []int{1, 1}, a)

	delta := tile_carry_delta(old_bake, live, a)
	testing.expect_value(t, delta.edits[0].tile_name, "floor")

	carried := tile_carry_apply(delta, new_bake, a)
	testing.expect_value(t, carried[0].cells[0], 0)
	ver := World_Version {
		tilemaps = carried,
	}
	layer := version_tilemap(&ver, "terrain")
	name, has := tilemap_tile_at(layer, 0, 0)
	testing.expect(t, has)
	testing.expect_value(t, name, "floor")
}
