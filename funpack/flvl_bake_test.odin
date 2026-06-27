package funpack

import "core:testing"

SCHEMA_SOURCE :: `
import engine.math.{Fixed, Vec2}
import engine.world.Ref
thing Player { pos: Vec2 }
thing Switch { pos: Vec2, on: Bool = false }
thing Door { pos: Vec2, gate: Ref[Switch], open: Bool = false }
thing Pillar { pos: Vec2 }
thing Base { pos: Vec2 }
thing Cannon { pos: Vec2, rate: Fixed }
`

bake_fixture :: proc(t: ^testing.T, schema_src, level_src: string) -> (baked: Baked_Level, err: Bake_Error) {
	schema_ast, schema_parse := stage_parse(stage_lex(schema_src))
	testing.expect_value(t, schema_parse, Parse_Error.None)
	level, level_parse := parse_flvl(level_src)
	testing.expect_value(t, level_parse, Flvl_Parse_Error.None)
	index := build_module_index_from_asts({"arena_world"}, {schema_ast})
	return bake_flvl(level, schema_ast, "arena_world", index)
}

CLEAN_LEVEL :: `
level Arena 2d {
  bounds (0, 0) (160, 120)
  things arena_world

  prefab Turret {
    place Base   base   at origin
    place Cannon cannon { rate: 2.0 } at base.offset(y: 6)
  }

  place Player hero at center
  place Switch plate at center.offset(y: 40)
  place Door   exit  { gate: plate } at center.offset(y: -40)
  for i in 0..5 {
    place Pillar at center.offset(x: -48 + i * 24, y: 0)
  }
  place Turret right_gun { cannon.rate: 4.0 } at right_edge.center.offset(x: -12)
}
`

@(test)
test_flvl_bake_clean_fixture :: proc(t: ^testing.T) {
	baked, err := bake_fixture(t, SCHEMA_SOURCE, CLEAN_LEVEL)
	testing.expect_value(t, err, Bake_Error.None)
	testing.expect_value(t, baked.level_name, "Arena")

	testing.expect_value(t, len(baked.refs), 5)
	hero, has_hero := find_baked_ref(baked.refs, "Arena.hero")
	testing.expect(t, has_hero)
	testing.expect_value(t, hero.thing_type, "Player")
	exit, has_exit := find_baked_ref(baked.refs, "Arena.exit")
	testing.expect(t, has_exit)
	testing.expect_value(t, exit.thing_type, "Door")
	cannon, has_cannon := find_baked_ref(baked.refs, "Arena.right_gun.cannon")
	testing.expect(t, has_cannon)
	testing.expect_value(t, cannon.thing_type, "Cannon")

	testing.expect_value(t, len(baked.spawns), 10)
	testing.expect_value(t, baked.spawns[0].thing_type, "Player")
	testing.expect_value(t, baked.spawns[1].thing_type, "Switch")
	testing.expect_value(t, baked.spawns[2].thing_type, "Door")
	testing.expect_value(t, baked.spawns[3].thing_type, "Pillar")
	testing.expect_value(t, baked.spawns[7].thing_type, "Pillar")
	testing.expect_value(t, baked.spawns[8].thing_type, "Base")
	testing.expect_value(t, baked.spawns[9].thing_type, "Cannon")

	testing.expect_value(t, len(baked.prefabs), 1)
	testing.expect_value(t, baked.prefabs[0].name, "Arena.right_gun")
	testing.expect_value(t, baked.prefabs[0].type, "Turret")
	testing.expect_value(t, len(baked.prefabs[0].members), 2)

	plate, has_plate := find_baked_ref(baked.refs, "Arena.plate")
	testing.expect(t, has_plate)
	door_spawn := baked.spawns[2]
	testing.expect_value(t, len(door_spawn.params), 1)
	testing.expect(t, door_spawn.params[0].is_ref)
	testing.expect_value(t, door_spawn.params[0].field, "gate")
	testing.expect_value(t, door_spawn.params[0].ref_id, plate.id)

	cannon_spawn := baked.spawns[9]
	rate, has_rate := find_baked_param(cannon_spawn.params, "rate")
	testing.expect(t, has_rate)
	testing.expect_value(t, rate.value, to_fixed(4))
}

@(test)
test_flvl_bake_stable_name_ids :: proc(t: ^testing.T) {
	baked, err := bake_fixture(t, SCHEMA_SOURCE, CLEAN_LEVEL)
	testing.expect_value(t, err, Bake_Error.None)

	hero, _ := find_baked_ref(baked.refs, "Arena.hero")
	plate, _ := find_baked_ref(baked.refs, "Arena.plate")
	testing.expect_value(t, hero.id, flvl_stable_id("Arena.hero"))
	testing.expect_value(t, plate.id, flvl_stable_id("Arena.plate"))
	testing.expect(t, hero.id != plate.id)
	cannon, _ := find_baked_ref(baked.refs, "Arena.right_gun.cannon")
	testing.expect_value(t, cannon.id, flvl_stable_id("Arena.right_gun.cannon"))
}

@(test)
test_flvl_bake_fixed_point_coords :: proc(t: ^testing.T) {
	baked, err := bake_fixture(t, SCHEMA_SOURCE, CLEAN_LEVEL)
	testing.expect_value(t, err, Bake_Error.None)

	hero_spawn := baked.spawns[0]
	testing.expect_value(t, hero_spawn.pos.x, to_fixed(80))
	testing.expect_value(t, hero_spawn.pos.y, to_fixed(60))

	plate_spawn := baked.spawns[1]
	testing.expect_value(t, plate_spawn.pos.x, to_fixed(80))
	testing.expect_value(t, plate_spawn.pos.y, to_fixed(100))

	first_pillar := baked.spawns[3]
	testing.expect_value(t, first_pillar.pos.x, to_fixed(32))
	testing.expect_value(t, first_pillar.pos.y, to_fixed(60))
	last_pillar := baked.spawns[7]
	testing.expect_value(t, last_pillar.pos.x, to_fixed(128))

	base_spawn := baked.spawns[8]
	testing.expect_value(t, base_spawn.pos.x, to_fixed(148))
	testing.expect_value(t, base_spawn.pos.y, to_fixed(60))
	cannon_spawn := baked.spawns[9]
	testing.expect_value(t, cannon_spawn.pos.y, to_fixed(66))
}

@(test)
test_flvl_gate_unresolved_name :: proc(t: ^testing.T) {
	level := `
level Arena 2d {
  bounds (0, 0) (160, 120)
  things arena_world
  place Door exit { gate: ghost } at center
}
`
	_, err := bake_fixture(t, SCHEMA_SOURCE, level)
	testing.expect_value(t, err, Bake_Error.Unresolved_Name)
}

@(test)
test_flvl_gate_duplicate_name :: proc(t: ^testing.T) {
	level := `
level Arena 2d {
  bounds (0, 0) (160, 120)
  things arena_world
  place Player hero at center
  place Player hero at center.offset(x: 10)
}
`
	_, err := bake_fixture(t, SCHEMA_SOURCE, level)
	testing.expect_value(t, err, Bake_Error.Duplicate_Name)
}

@(test)
test_flvl_gate_type_mismatched_ref :: proc(t: ^testing.T) {
	level := `
level Arena 2d {
  bounds (0, 0) (160, 120)
  things arena_world
  place Player hero at center
  place Door exit { gate: hero } at center.offset(y: -40)
}
`
	_, err := bake_fixture(t, SCHEMA_SOURCE, level)
	testing.expect_value(t, err, Bake_Error.Type_Mismatched_Ref)
}

@(test)
test_flvl_gate_param_not_on_schema :: proc(t: ^testing.T) {
	level := `
level Arena 2d {
  bounds (0, 0) (160, 120)
  things arena_world
  place Player hero { speed: 5 } at center
}
`
	_, err := bake_fixture(t, SCHEMA_SOURCE, level)
	testing.expect_value(t, err, Bake_Error.Param_Not_On_Schema)
}

@(test)
test_flvl_gate_at_without_pos :: proc(t: ^testing.T) {
	schema := `
import engine.math.{Vec2}
thing Player { pos: Vec2 }
`
	level := `
level Arena 3d {
  bounds (0, 0, 0) (160, 120, 80)
  things arena_world
  place Player hero at center
}
`
	_, err := bake_fixture(t, schema, level)
	testing.expect_value(t, err, Bake_Error.At_Without_Pos)
}

@(test)
test_flvl_gate_outside_bounds :: proc(t: ^testing.T) {
	level := `
level Arena 2d {
  bounds (0, 0) (160, 120)
  things arena_world
  place Player hero at center.offset(x: 200)
}
`
	_, err := bake_fixture(t, SCHEMA_SOURCE, level)
	testing.expect_value(t, err, Bake_Error.Outside_Bounds)
}

@(test)
test_flvl_gate_seam_imports_behavior :: proc(t: ^testing.T) {
	behavior_src := `
thing Player { pos: Int }
behavior chase on Player { fn step(p: Player) -> Player { return p } }
`
	schema_only_src := `thing Switch { pos: Int }`
	behavior_ast, b_parse := stage_parse(stage_lex(behavior_src))
	testing.expect_value(t, b_parse, Parse_Error.None)
	schema_ast, s_parse := stage_parse(stage_lex(schema_only_src))
	testing.expect_value(t, s_parse, Parse_Error.None)

	module_asts := make(map[string]Ast, 4, context.temp_allocator)
	module_asts["arena_game"] = behavior_ast
	module_asts["arena_world"] = schema_ast

	seam_bad_src := `import arena_game.{Player}`
	seam_bad, sb_parse := stage_parse(stage_lex(seam_bad_src))
	testing.expect_value(t, sb_parse, Parse_Error.None)
	testing.expect_value(t, check_flvl_seam_layering(seam_bad, module_asts), Bake_Error.Seam_Imports_Behavior)

	seam_ok_src := `import arena_world.{Switch}`
	seam_ok, so_parse := stage_parse(stage_lex(seam_ok_src))
	testing.expect_value(t, so_parse, Parse_Error.None)
	testing.expect_value(t, check_flvl_seam_layering(seam_ok, module_asts), Bake_Error.None)
}

@(test)
test_flvl_gate_prefab_member_not_placed :: proc(t: ^testing.T) {
	level := `
level Arena 2d {
  bounds (0, 0) (160, 120)
  things arena_world
  prefab Turret {
    place Base   base   at origin
    place Cannon cannon { rate: 2.0 } at base.offset(y: 6)
  }
  place Turret right_gun { turret.rate: 4.0 } at center
}
`
	_, err := bake_fixture(t, SCHEMA_SOURCE, level)
	testing.expect_value(t, err, Bake_Error.Prefab_Member_Not_Placed)
}

tile_table_fixture :: proc(t: ^testing.T) -> []Project_Tile {
	tiles := make([]Tileset_Tile, 2, context.temp_allocator)
	tiles[0] = Tileset_Tile{name = "wall", cell_x = 1, cell_y = 0, solid = true}
	tiles[1] = Tileset_Tile{name = "floor", cell_x = 0, cell_y = 0, solid = false}
	sets := make([]Tileset_Asset, 1, context.temp_allocator)
	sets[0] = Tileset_Asset{name = "Fixture", atlas = "fix", tiles = tiles}
	table, err := flvl_project_tile_table(sets, context.temp_allocator)
	testing.expect_value(t, err, Bake_Error.None)
	return table
}

bake_tile_fixture :: proc(t: ^testing.T, schema_src, level_src: string, tiles: []Project_Tile) -> (baked: Baked_Level, err: Bake_Error) {
	schema_ast, schema_parse := stage_parse(stage_lex(schema_src))
	testing.expect_value(t, schema_parse, Parse_Error.None)
	level, level_parse := parse_flvl(level_src)
	testing.expect_value(t, level_parse, Flvl_Parse_Error.None)
	index := build_module_index_from_asts({"arena_world"}, {schema_ast})
	return bake_flvl(level, schema_ast, "arena_world", index, tiles)
}

TILEMAP_LEVEL :: `
level Arena 2d {
  bounds (0, 0) (64, 48)
  things arena_world

  tilemap terrain cell 16 {
    legend {
      '#' wall
      '.' floor
      'g' spawn Pillar
      'P' spawn Player hero
      ' ' empty
    }
    grid """
      ####
      #P.g
      # ##
    """
  }

  place Switch plate at cell(1, 2)
}
`

@(test)
test_flvl_bake_tilemap_clean_fixture :: proc(t: ^testing.T) {
	baked, err := bake_tile_fixture(t, SCHEMA_SOURCE, TILEMAP_LEVEL, tile_table_fixture(t))
	testing.expect_value(t, err, Bake_Error.None)

	testing.expect_value(t, len(baked.tile_layers), 1)
	layer := baked.tile_layers[0]
	testing.expect_value(t, layer.name, "terrain")
	testing.expect_value(t, layer.cell_size, 16)
	testing.expect_value(t, layer.cols, 4)
	testing.expect_value(t, layer.rows, 3)
	testing.expect_value(t, len(layer.palette), 2)
	testing.expect_value(t, layer.palette[0].name, "wall")
	testing.expect_value(t, layer.palette[0].solid, true)
	testing.expect_value(t, layer.palette[1].name, "floor")
	testing.expect_value(t, layer.palette[1].solid, false)

	testing.expect_value(t, len(layer.cells), 12)
	expected_cells := []int{
		0, 0, 0, 0,
		0, TILE_LAYER_EMPTY_CELL, 1, TILE_LAYER_EMPTY_CELL,
		0, TILE_LAYER_EMPTY_CELL, 0, 0,
	}
	for want, i in expected_cells {
		testing.expect_value(t, layer.cells[i], want)
	}

	testing.expect_value(t, len(baked.spawns), 3)
	testing.expect_value(t, baked.spawns[0].thing_type, "Player")
	testing.expect_value(t, baked.spawns[1].thing_type, "Pillar")
	testing.expect_value(t, baked.spawns[2].thing_type, "Switch")

	testing.expect_value(t, baked.spawns[0].pos.x, to_fixed(24))
	testing.expect_value(t, baked.spawns[0].pos.y, to_fixed(24))
	testing.expect_value(t, baked.spawns[1].pos.x, to_fixed(56))
	testing.expect_value(t, baked.spawns[1].pos.y, to_fixed(24))

	testing.expect_value(t, baked.spawns[2].pos.x, to_fixed(24))
	testing.expect_value(t, baked.spawns[2].pos.y, to_fixed(8))

	hero, has_hero := find_baked_ref(baked.refs, "Arena.hero")
	testing.expect(t, has_hero)
	testing.expect_value(t, hero.thing_type, "Player")
	testing.expect_value(t, hero.id, flvl_stable_id("Arena.hero"))
	testing.expect_value(t, baked.spawns[1].id, 0)
	testing.expect_value(t, len(baked.symbols), 2)
	testing.expect_value(t, baked.symbols[0].local_name, "hero")
	testing.expect_value(t, baked.symbols[1].local_name, "plate")
}

@(test)
test_flvl_gate_char_not_in_legend :: proc(t: ^testing.T) {
	level := `
level Arena 2d {
  bounds (0, 0) (64, 48)
  things arena_world
  tilemap terrain cell 16 {
    legend {
      '#' wall
    }
    grid """
      ####
      #?##
      ####
    """
  }
}
`
	_, err := bake_tile_fixture(t, SCHEMA_SOURCE, level, tile_table_fixture(t))
	testing.expect_value(t, err, Bake_Error.Char_Not_In_Legend)
}

@(test)
test_flvl_gate_grid_not_rectangular :: proc(t: ^testing.T) {
	level := `
level Arena 2d {
  bounds (0, 0) (64, 48)
  things arena_world
  tilemap terrain cell 16 {
    legend {
      '#' wall
    }
    grid """
      ####
      ###
      ####
    """
  }
}
`
	_, err := bake_tile_fixture(t, SCHEMA_SOURCE, level, tile_table_fixture(t))
	testing.expect_value(t, err, Bake_Error.Grid_Not_Rectangular)
}

@(test)
test_flvl_gate_unknown_tile_name :: proc(t: ^testing.T) {
	level := `
level Arena 2d {
  bounds (0, 0) (64, 48)
  things arena_world
  tilemap terrain cell 16 {
    legend {
      '#' wall
      'L' lava
    }
    grid """
      ####
      ####
      ####
    """
  }
}
`
	_, err := bake_tile_fixture(t, SCHEMA_SOURCE, level, tile_table_fixture(t))
	testing.expect_value(t, err, Bake_Error.Unknown_Tile_Name)
}

@(test)
test_flvl_gate_tile_name_collision :: proc(t: ^testing.T) {
	first := make([]Tileset_Tile, 1, context.temp_allocator)
	first[0] = Tileset_Tile{name = "wall", solid = true}
	second := make([]Tileset_Tile, 1, context.temp_allocator)
	second[0] = Tileset_Tile{name = "wall", solid = false}
	sets := make([]Tileset_Asset, 2, context.temp_allocator)
	sets[0] = Tileset_Asset{name = "A", atlas = "a", tiles = first}
	sets[1] = Tileset_Asset{name = "B", atlas = "b", tiles = second}
	_, err := flvl_project_tile_table(sets, context.temp_allocator)
	testing.expect_value(t, err, Bake_Error.Tile_Name_Collision)
}

@(test)
test_flvl_gate_duplicate_named_marker :: proc(t: ^testing.T) {
	level := `
level Arena 2d {
  bounds (0, 0) (64, 48)
  things arena_world
  tilemap terrain cell 16 {
    legend {
      '#' wall
      'P' spawn Player hero
    }
    grid """
      ####
      #PP#
      ####
    """
  }
}
`
	_, err := bake_tile_fixture(t, SCHEMA_SOURCE, level, tile_table_fixture(t))
	testing.expect_value(t, err, Bake_Error.Duplicate_Name)
}

@(test)
test_flvl_gate_cell_outside_grid :: proc(t: ^testing.T) {
	out_of_range := `
level Arena 2d {
  bounds (0, 0) (64, 48)
  things arena_world
  tilemap terrain cell 16 {
    legend {
      '#' wall
    }
    grid """
      ####
      ####
      ####
    """
  }
  place Switch plate at cell(9, 9)
}
`
	_, err := bake_tile_fixture(t, SCHEMA_SOURCE, out_of_range, tile_table_fixture(t))
	testing.expect_value(t, err, Bake_Error.Cell_Outside_Grid)

	no_grid := `
level Arena 2d {
  bounds (0, 0) (64, 48)
  things arena_world
  place Switch plate at cell(0, 0)
}
`
	_, no_grid_err := bake_tile_fixture(t, SCHEMA_SOURCE, no_grid, tile_table_fixture(t))
	testing.expect_value(t, no_grid_err, Bake_Error.Cell_Outside_Grid)
}

@(test)
test_flvl_gate_marker_unknown_thing :: proc(t: ^testing.T) {
	level := `
level Arena 2d {
  bounds (0, 0) (64, 48)
  things arena_world
  tilemap terrain cell 16 {
    legend {
      '#' wall
      'x' spawn Ghost
    }
    grid """
      ####
      #x##
      ####
    """
  }
}
`
	_, err := bake_tile_fixture(t, SCHEMA_SOURCE, level, tile_table_fixture(t))
	testing.expect_value(t, err, Bake_Error.Unknown_Thing_Type)
}

@(test)
test_flvl_gate_marker_without_pos :: proc(t: ^testing.T) {
	schema := `
import engine.math.{Vec2}
thing Player { pos: Vec2 }
thing Gem { score: Int }
`
	level := `
level Arena 2d {
  bounds (0, 0) (64, 48)
  things arena_world
  tilemap terrain cell 16 {
    legend {
      '#' wall
      'j' spawn Gem
    }
    grid """
      ####
      #j##
      ####
    """
  }
}
`
	_, err := bake_tile_fixture(t, schema, level, tile_table_fixture(t))
	testing.expect_value(t, err, Bake_Error.At_Without_Pos)
}

find_baked_ref :: proc(refs: []Baked_Ref, qualified: string) -> (ref: Baked_Ref, found: bool) {
	for candidate in refs {
		if candidate.name == qualified {
			return candidate, true
		}
	}
	return Baked_Ref{}, false
}

find_baked_param :: proc(params: []Baked_Param, field: string) -> (param: Baked_Param, found: bool) {
	for candidate in params {
		if candidate.field == field {
			return candidate, true
		}
	}
	return Baked_Param{}, false
}
