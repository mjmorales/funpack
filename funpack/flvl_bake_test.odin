// §17 level-bake fixtures (spec §17.1–§17.4). The bake lowers a parsed `.flvl`
// against its `things` schema module into the typed Ref table, the deterministic
// spawn list, and every §17.4 gate. These are HAND-BUILT schema+level fixtures
// (no spec golden checkout, no byte-match — that is the leaf story): a small
// schema module that bakes a clean level, plus ONE rejecting fixture per gate
// arm asserting the specific Bake_Error.
//
// The schema module is a real parsed .fun source (stage_parse over a hand-built
// thing schema), so a Ref[T] field, a `pos: Vec2`, and a `rate: Fixed` carry the
// genuine Field_Decl/Type_Ref shapes the bake reads; the level is a real
// parse_flvl over flat text. build_module_index_from_asts wires the schema module
// into the index the bake resolves `things <module>` against — the same seam the
// multi-module fixtures use.
package funpack

import "core:testing"

// SCHEMA_SOURCE is the hand-built `arena_world` schema module: the placeable
// thing types the fixtures place, with a Ref[Switch]-gated Door (the
// reference-by-name target) and a Fixed-rate Cannon (the prefab override
// target). Schema only — no behaviors — so it is a valid §17.2 schema module.
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

// bake_fixture parses a schema source and a level source, builds the project
// index over the schema module, and bakes the level — the shared fixture wiring
// every test below funnels through. The schema module name is `arena_world`,
// matching the `things arena_world` line the level sources carry.
bake_fixture :: proc(t: ^testing.T, schema_src, level_src: string) -> (baked: Baked_Level, err: Bake_Error) {
	schema_ast, schema_parse := stage_parse(stage_lex(schema_src))
	testing.expect_value(t, schema_parse, Parse_Error.None)
	level, level_parse := parse_flvl(level_src)
	testing.expect_value(t, level_parse, Flvl_Parse_Error.None)
	index := build_module_index_from_asts({"arena_world"}, {schema_ast})
	return bake_flvl(level, schema_ast, "arena_world", index)
}

// CLEAN_LEVEL is the canonical clean fixture: a 2d arena with a player, a
// switch, a switch-gated door (reference-by-name `gate: plate`), a five-iteration
// pillar loop, and a Turret prefab placement with a nested-field override
// (`cannon.rate: 4.0`). It exercises every clean-path mechanism — anchors,
// offset arithmetic, the loop var, a prefab + override, a typed Ref — at once.
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
	// AC: the clean fixture bakes to the expected Ref table and spawn list. The
	// Ref table is the five NAMED instances (hero, plate, exit, and the prefab's
	// two members); the prefab instance itself is a Baked_Prefab_Instance, not a
	// Ref. The spawn list is declaration order with the loop and prefab expanded
	// in place: hero, plate, exit, 5 pillars, base, cannon = 10 spawns.
	baked, err := bake_fixture(t, SCHEMA_SOURCE, CLEAN_LEVEL)
	testing.expect_value(t, err, Bake_Error.None)
	testing.expect_value(t, baked.level_name, "Arena")

	// Five named Refs: hero, plate, exit, right_gun.base, right_gun.cannon.
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

	// The deterministic spawn list: 10 entries (1 player + 1 switch + 1 door +
	// 5 pillars + base + cannon), declaration order with the loop/prefab expanded
	// in place.
	testing.expect_value(t, len(baked.spawns), 10)
	testing.expect_value(t, baked.spawns[0].thing_type, "Player")
	testing.expect_value(t, baked.spawns[1].thing_type, "Switch")
	testing.expect_value(t, baked.spawns[2].thing_type, "Door")
	testing.expect_value(t, baked.spawns[3].thing_type, "Pillar")
	testing.expect_value(t, baked.spawns[7].thing_type, "Pillar")
	testing.expect_value(t, baked.spawns[8].thing_type, "Base")
	testing.expect_value(t, baked.spawns[9].thing_type, "Cannon")

	// The one prefab instance (right_gun) expands to its two member Refs.
	testing.expect_value(t, len(baked.prefabs), 1)
	testing.expect_value(t, baked.prefabs[0].name, "Arena.right_gun")
	testing.expect_value(t, baked.prefabs[0].type, "Turret")
	testing.expect_value(t, len(baked.prefabs[0].members), 2)

	// The reference-by-name `gate: plate` on the Door resolves to a Ref param
	// pointing at the `plate` instance's stable Id.
	plate, has_plate := find_baked_ref(baked.refs, "Arena.plate")
	testing.expect(t, has_plate)
	door_spawn := baked.spawns[2]
	testing.expect_value(t, len(door_spawn.params), 1)
	testing.expect(t, door_spawn.params[0].is_ref)
	testing.expect_value(t, door_spawn.params[0].field, "gate")
	testing.expect_value(t, door_spawn.params[0].ref_id, plate.id)

	// The nested-field override `cannon.rate: 4.0` reaches the prefab's Cannon
	// member: its `rate` param is the overridden 4.0, not the prefab default 2.0.
	cannon_spawn := baked.spawns[9]
	rate, has_rate := find_baked_param(cannon_spawn.params, "rate")
	testing.expect(t, has_rate)
	testing.expect_value(t, rate.value, to_fixed(4))
}

@(test)
test_flvl_bake_stable_name_ids :: proc(t: ^testing.T) {
	// AC: a named instance's Id is derived from its level-qualified name and is
	// stable — the same name bakes to the same Id, a different name to a different
	// Id (spec §17.2 "stable ids by name"). The qualified name `Arena.hero` keys
	// the Id, so the Id is reproducible and rename-sensitive.
	baked, err := bake_fixture(t, SCHEMA_SOURCE, CLEAN_LEVEL)
	testing.expect_value(t, err, Bake_Error.None)

	hero, _ := find_baked_ref(baked.refs, "Arena.hero")
	plate, _ := find_baked_ref(baked.refs, "Arena.plate")
	// The Id is the deterministic hash of the qualified name — recomputable.
	testing.expect_value(t, hero.id, stable_id("Arena.hero"))
	testing.expect_value(t, plate.id, stable_id("Arena.plate"))
	// Distinct names → distinct Ids (no collision among the fixture's names).
	testing.expect(t, hero.id != plate.id)
	// A prefab member's Id keys off its deep qualified name.
	cannon, _ := find_baked_ref(baked.refs, "Arena.right_gun.cannon")
	testing.expect_value(t, cannon.id, stable_id("Arena.right_gun.cannon"))
}

@(test)
test_flvl_bake_fixed_point_coords :: proc(t: ^testing.T) {
	// AC: an `at` resolves to a fixed-point coordinate by anchoring + folding the
	// offset arithmetic (spec §17.4 — coordinates are fixed-point so a level loads
	// bit-identically). center = (80, 60); `center.offset(y: 40)` = (80, 100);
	// the loop's `center.offset(x: -48 + i*24)` walks 32, 56, 80, 104, 128 in x.
	baked, err := bake_fixture(t, SCHEMA_SOURCE, CLEAN_LEVEL)
	testing.expect_value(t, err, Bake_Error.None)

	// hero at center: bounds (0,0)-(160,120) → center (80, 60), exact Fixed bits.
	hero_spawn := baked.spawns[0]
	testing.expect_value(t, hero_spawn.pos.x, to_fixed(80))
	testing.expect_value(t, hero_spawn.pos.y, to_fixed(60))

	// plate at center.offset(y: 40): (80, 100).
	plate_spawn := baked.spawns[1]
	testing.expect_value(t, plate_spawn.pos.x, to_fixed(80))
	testing.expect_value(t, plate_spawn.pos.y, to_fixed(100))

	// The pillar loop folds `-48 + i * 24` over the kernel: i=0 → x=32, i=4 → 128.
	first_pillar := baked.spawns[3]
	testing.expect_value(t, first_pillar.pos.x, to_fixed(32))
	testing.expect_value(t, first_pillar.pos.y, to_fixed(60))
	last_pillar := baked.spawns[7]
	testing.expect_value(t, last_pillar.pos.x, to_fixed(128))

	// The prefab member `cannon at base.offset(y: 6)` against the placement
	// origin (right_edge.center.offset(x: -12) = (148, 60)): base at (148, 60),
	// cannon at (148, 66).
	base_spawn := baked.spawns[8]
	testing.expect_value(t, base_spawn.pos.x, to_fixed(148))
	testing.expect_value(t, base_spawn.pos.y, to_fixed(60))
	cannon_spawn := baked.spawns[9]
	testing.expect_value(t, cannon_spawn.pos.y, to_fixed(66))
}

// ── §17.4 gate rejections (one fixture per arm) ─────────────────────────────

@(test)
test_flvl_gate_unresolved_name :: proc(t: ^testing.T) {
	// A reference-by-name (`gate: ghost`) naming no placed instance is the
	// unresolved-name compile error — dangling references are unrepresentable.
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
	// Two named instances sharing a level-qualified name is the duplicate-name
	// compile error.
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
	// A Ref[Switch] field (`gate`) bound to an instance whose thing type is NOT
	// Switch (here a Player) is the type-mismatched-ref compile error.
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
	// A param key (`speed`) that is not a field of the placed thing's schema is
	// the param-not-on-schema compile error.
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
	// A thing placed with `at` must declare a `pos` of the level's arity. A 3d
	// level placing a thing whose `pos` is Vec2 (the wrong arity) is the
	// at-without-pos (dimensionality) compile error.
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
	// A resolved coordinate outside the level's bounds is the out-of-bounds
	// compile error. `center.offset(x: 200)` on a 160-wide level lands at x=280,
	// past the right bound.
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
	// §17.2 layering: a generated `.gen.fun` seam imports schema modules only — a
	// seam importing a behavior module (one declaring a `behavior`/`pipeline`) is
	// the seam-imports-behavior compile error. The seam's import of `arena_game`,
	// a behavior module, rejects; an import of the schema module `arena_world`
	// does not.
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

	// A seam importing the behavior module rejects.
	seam_bad_src := `import arena_game.{Player}`
	seam_bad, sb_parse := stage_parse(stage_lex(seam_bad_src))
	testing.expect_value(t, sb_parse, Parse_Error.None)
	testing.expect_value(t, check_flvl_seam_layering(seam_bad, module_asts), Bake_Error.Seam_Imports_Behavior)

	// A seam importing the schema module only is clean.
	seam_ok_src := `import arena_world.{Switch}`
	seam_ok, so_parse := stage_parse(stage_lex(seam_ok_src))
	testing.expect_value(t, so_parse, Parse_Error.None)
	testing.expect_value(t, check_flvl_seam_layering(seam_ok, module_asts), Bake_Error.None)
}

@(test)
test_flvl_gate_prefab_member_not_placed :: proc(t: ^testing.T) {
	// A prefab override naming a member the prefab never places is the
	// prefab-member-not-placed compile error. The Turret prefab places `base` and
	// `cannon`; an override `turret.rate` names `turret`, which it never places.
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

// ── §18 §3 tilemap layer fixtures ───────────────────────────────────────────

// tile_table_fixture builds the project-global tile table from one hand-built
// tileset (wall solid, floor passable) — the §18 §3 namespace the tilemap
// fixtures' legends resolve through.
tile_table_fixture :: proc(t: ^testing.T) -> []Project_Tile {
	tiles := make([]Tileset_Tile, 2, context.temp_allocator)
	tiles[0] = Tileset_Tile{name = "wall", cell_x = 1, cell_y = 0, solid = true}
	tiles[1] = Tileset_Tile{name = "floor", cell_x = 0, cell_y = 0, solid = false}
	sets := make([]Tileset_Asset, 1, context.temp_allocator)
	sets[0] = Tileset_Asset{name = "Fixture", atlas = "fix", tiles = tiles}
	table, err := project_tile_table(sets, context.temp_allocator)
	testing.expect_value(t, err, Bake_Error.None)
	return table
}

// bake_tile_fixture is bake_fixture with the project tile table supplied — the
// shared wiring for every tilemap-bearing fixture below.
bake_tile_fixture :: proc(t: ^testing.T, schema_src, level_src: string, tiles: []Project_Tile) -> (baked: Baked_Level, err: Bake_Error) {
	schema_ast, schema_parse := stage_parse(stage_lex(schema_src))
	testing.expect_value(t, schema_parse, Parse_Error.None)
	level, level_parse := parse_flvl(level_src)
	testing.expect_value(t, level_parse, Flvl_Parse_Error.None)
	index := build_module_index_from_asts({"arena_world"}, {schema_ast})
	return bake_flvl(level, schema_ast, "arena_world", index, tiles)
}

// TILEMAP_LEVEL is the canonical clean tilemap fixture: a 4×3 grid (cell 16,
// exactly the 64×48 bounds) carrying both tile binds, an anonymous marker, a
// named marker, an empty cell, and a `cell()`-anchored place after the layer.
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
	// AC: the layer bakes to its tile-layer model, the markers bake to spawns
	// row-major, the named marker is a Ref + seam symbol, and the cell()
	// anchor resolves against the grid — the §18 §3 lowering end-to-end.
	baked, err := bake_tile_fixture(t, SCHEMA_SOURCE, TILEMAP_LEVEL, tile_table_fixture(t))
	testing.expect_value(t, err, Bake_Error.None)

	// One layer: 4×3 at cell 16, palette in LEGEND order (wall, floor) with
	// the §18 §2 collision verdicts carried.
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

	// The row-major cells: a tile cell carries its palette index; the marker
	// and empty cells carry no tile (a marker paints no terrain).
	testing.expect_value(t, len(layer.cells), 12)
	expected_cells := []int{
		0, 0, 0, 0,
		0, TILE_LAYER_EMPTY_CELL, 1, TILE_LAYER_EMPTY_CELL,
		0, TILE_LAYER_EMPTY_CELL, 0, 0,
	}
	for want, i in expected_cells {
		testing.expect_value(t, layer.cells[i], want)
	}

	// Spawns in declaration order, the layer's markers row-major first: the
	// named hero (row 1, col 1), the anonymous pillar (row 1, col 3), then the
	// cell()-anchored switch.
	testing.expect_value(t, len(baked.spawns), 3)
	testing.expect_value(t, baked.spawns[0].thing_type, "Player")
	testing.expect_value(t, baked.spawns[1].thing_type, "Pillar")
	testing.expect_value(t, baked.spawns[2].thing_type, "Switch")

	// Marker positions are CELL CENTERS, row 0 at the level's top edge:
	// hero (1,1) → (24, 24); pillar (3,1) → (56, 24) on the 48-high bounds.
	testing.expect_value(t, baked.spawns[0].pos.x, to_fixed(24))
	testing.expect_value(t, baked.spawns[0].pos.y, to_fixed(24))
	testing.expect_value(t, baked.spawns[1].pos.x, to_fixed(56))
	testing.expect_value(t, baked.spawns[1].pos.y, to_fixed(24))

	// The cell(1, 2) anchor is the same mapping: (24, 8).
	testing.expect_value(t, baked.spawns[2].pos.x, to_fixed(24))
	testing.expect_value(t, baked.spawns[2].pos.y, to_fixed(8))

	// The named marker is a Ref with its name-derived stable Id and a seam
	// symbol; the anonymous marker takes a counter id (declaration order 0).
	hero, has_hero := find_baked_ref(baked.refs, "Arena.hero")
	testing.expect(t, has_hero)
	testing.expect_value(t, hero.thing_type, "Player")
	testing.expect_value(t, hero.id, stable_id("Arena.hero"))
	testing.expect_value(t, baked.spawns[1].id, 0)
	testing.expect_value(t, len(baked.symbols), 2)
	testing.expect_value(t, baked.symbols[0].local_name, "hero")
	testing.expect_value(t, baked.symbols[1].local_name, "plate")
}

// ── §18 §5 tilemap gate rejections (one fixture per arm) ────────────────────

@(test)
test_flvl_gate_char_not_in_legend :: proc(t: ^testing.T) {
	// A grid char no legend entry binds is the legend-less-char compile error.
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
	// Dedented rows of unequal length are the non-rectangular-grid compile
	// error — the gate runs AFTER the common-indent strip, so a genuinely
	// ragged row (not block indentation) trips it.
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
	// A legend tile name absent from the project-global table is the
	// unknown-tile-name compile error — declared is gated, used or not (the
	// `lava` char never appears in the grid).
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
	// Two tilesets declaring the same tile name is the cross-tileset
	// collision compile error (one name, one tile — the ADR's project-global
	// namespace rule).
	first := make([]Tileset_Tile, 1, context.temp_allocator)
	first[0] = Tileset_Tile{name = "wall", solid = true}
	second := make([]Tileset_Tile, 1, context.temp_allocator)
	second[0] = Tileset_Tile{name = "wall", solid = false}
	sets := make([]Tileset_Asset, 2, context.temp_allocator)
	sets[0] = Tileset_Asset{name = "A", atlas = "a", tiles = first}
	sets[1] = Tileset_Asset{name = "B", atlas = "b", tiles = second}
	_, err := project_tile_table(sets, context.temp_allocator)
	testing.expect_value(t, err, Bake_Error.Tile_Name_Collision)
}

@(test)
test_flvl_gate_duplicate_named_marker :: proc(t: ^testing.T) {
	// A named marker must appear exactly once (§18 §3) — its second cell
	// claims the same level-qualified name, the duplicate-name compile error.
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
	// A `cell()` outside the grid is its own compile error: col 9 on a 4-wide
	// grid is out of range…
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

	// …and a cell() in a level with NO tilemap layer is the degenerate case of
	// the same gate — any cell is outside a grid that does not exist.
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
	// A marker whose thing type the schema does not declare is the same
	// unknown-thing-type compile error a `place` of it would be.
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
	// A marker cell writes the thing's `pos` like an `at` does, so a marker on
	// a thing with no `pos` of the level's arity is the at-without-pos gate.
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

// ── Test-local lookup helpers ───────────────────────────────────────────────

// find_baked_ref finds a Ref table entry by its level-qualified name, walked by
// index. Test-local: the bake's own find_ref keys on the BARE local name (the
// reference-by-name resolution key), while the assertions want the qualified
// name.
find_baked_ref :: proc(refs: []Baked_Ref, qualified: string) -> (ref: Baked_Ref, found: bool) {
	for candidate in refs {
		if candidate.name == qualified {
			return candidate, true
		}
	}
	return Baked_Ref{}, false
}

// find_baked_param finds a resolved spawn param by field name, walked by index.
find_baked_param :: proc(params: []Baked_Param, field: string) -> (param: Baked_Param, found: bool) {
	for candidate in params {
		if candidate.field == field {
			return candidate, true
		}
	}
	return Baked_Param{}, false
}
