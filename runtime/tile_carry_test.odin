// The §09 §4 / §18 §4 dynamic-tile carry acceptance fixtures (the dungeon-golden
// mold): ONE comprehensive proc `test_reload_tile` packs every arm of the carry
// kernel — hand-built bakes and committed layers, pins computed BY HAND from the
// fixture geometry, never read back from the implementation, sequential arms
// over `tile_carry_delta` / `tile_carry_apply` and the wired `migrate_world_version`
// swap path. The carry is the ADR 2026-06-11 ruling: dynamic tile state survives
// a reload swap, re-based name-keyed onto the new bake, new-bake-wins on every
// unmappable cell.
//
// AC1 and AC2 both run EXACTLY
//   odin test . -define:ODIN_TEST_NAMES=funpack_runtime.test_reload_tile
// and ODIN_TEST_NAMES is exact-match (no prefix glob), so EVERY assertion the
// two criteria depend on lives inside this one proc. Sibling procs below add
// extra coverage that runs only under the full `task test`.
package funpack_runtime

import "core:testing"

// tc_layer hand-builds a one-layer slice with an explicit palette and row-major
// cells — the bake/committed-layer fixture constructor. cols·rows == len(cells)
// by construction in every call below.
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

	// Shared 2-entry palette: wall (solid) = index 0, floor (non-solid) = index 1.
	wall_floor := []Tile_Def{{name = "wall", solid = true}, {name = "floor", solid = false}}

	// ===================================================================
	// ARM 1 (AC1): a dug cell SURVIVES an identical-level reload.
	// old_bake: a 3×1 row "wall wall wall" (all solid). SetTile floor@(1,0)
	// committed → live "wall floor wall". The reload recompiles the SAME level,
	// so new_bake == old_bake. The carried world must hold floor@(1,0): a reload
	// that does not touch the level preserves every live terrain edit (ADR).
	// ===================================================================
	{
		old_bake := make([]Tile_Layer, 1, a)
		old_bake[0] = tc_layer("terrain", 3, 1, wall_floor, []int{0, 0, 0}, a)
		// live: SetTile flipped cell (1,0) wall→floor (index 0 → 1).
		live := make([]Tile_Layer, 1, a)
		live[0] = tc_layer("terrain", 3, 1, wall_floor, []int{0, 1, 0}, a)
		// new_bake: identical recompile of the same level.
		new_bake := make([]Tile_Layer, 1, a)
		new_bake[0] = tc_layer("terrain", 3, 1, wall_floor, []int{0, 0, 0}, a)

		delta := tile_carry_delta(old_bake, live, a)
		// Exactly one edit: cell (1,0) carrying tile name "floor".
		testing.expect_value(t, len(delta.edits), 1)
		testing.expect_value(t, delta.edits[0].layer_name, "terrain")
		testing.expect_value(t, delta.edits[0].col, 1)
		testing.expect_value(t, delta.edits[0].row, 0)
		testing.expect_value(t, delta.edits[0].tile_name, "floor")

		carried := tile_carry_apply(delta, new_bake, a)
		// Query through version_tilemap over a World_Version{tilemaps=carried},
		// the production read path: the dug cell is floor (non-solid, name "floor").
		ver := World_Version {
			tilemaps = carried,
		}
		layer := version_tilemap(&ver, "terrain")
		testing.expect(t, layer != nil)
		testing.expect_value(t, tilemap_solid_at(layer, 1, 0), false)
		name, has := tilemap_tile_at(layer, 1, 0)
		testing.expect(t, has)
		testing.expect_value(t, name, "floor")
		// The untouched cells stay wall (solid) — only the dug cell moved.
		testing.expect_value(t, tilemap_solid_at(layer, 0, 0), true)
		testing.expect_value(t, tilemap_solid_at(layer, 2, 0), true)
		// COW: an EDITED layer fresh-copies its cells (not the new bake's slice).
		testing.expect(t, raw_data(carried[0].cells) != raw_data(new_bake[0].cells))
	}

	// ===================================================================
	// ARM 2 (AC2): drop rule — cell OUT OF the new grid.
	// old_bake/live: 3×1, SetTile floor@(2,0). new_bake: 2×1 (the level edit
	// SHRANK the grid). Edit (2,0) is past the new grid → dropped, new-bake-wins.
	// ===================================================================
	{
		old_bake := make([]Tile_Layer, 1, a)
		old_bake[0] = tc_layer("terrain", 3, 1, wall_floor, []int{0, 0, 0}, a)
		live := make([]Tile_Layer, 1, a)
		live[0] = tc_layer("terrain", 3, 1, wall_floor, []int{0, 0, 1}, a) // floor@(2,0)
		new_bake := make([]Tile_Layer, 1, a)
		new_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a) // shrunk to 2 cols

		delta := tile_carry_delta(old_bake, live, a)
		testing.expect_value(t, len(delta.edits), 1)
		testing.expect_value(t, delta.edits[0].col, 2)

		carried := tile_carry_apply(delta, new_bake, a)
		// Dropped: the layer took no landed edit, so its cells SHARE the new bake's
		// slice by reference (the COW fresh-copy fires only on a landed edit).
		testing.expect(t, raw_data(carried[0].cells) == raw_data(new_bake[0].cells))
		ver := World_Version {
			tilemaps = carried,
		}
		layer := version_tilemap(&ver, "terrain")
		testing.expect_value(t, layer.cols, 2)
		testing.expect_value(t, tilemap_solid_at(layer, 0, 0), true) // unchanged new bake
		testing.expect_value(t, tilemap_solid_at(layer, 1, 0), true)
	}

	// ===================================================================
	// ARM 3 (AC2): drop rule — tile NAME left the new palette.
	// old_bake/live carry a 3-entry palette incl "water"; SetTile water@(0,0).
	// new_bake's palette dropped "water" (only wall/floor remain) → the edit's
	// name resolves to -1 in the new palette → dropped.
	// ===================================================================
	{
		with_water := []Tile_Def {
			{name = "wall", solid = true},
			{name = "floor", solid = false},
			{name = "water", solid = false},
		}
		old_bake := make([]Tile_Layer, 1, a)
		old_bake[0] = tc_layer("terrain", 2, 1, with_water, []int{0, 0}, a)
		live := make([]Tile_Layer, 1, a)
		live[0] = tc_layer("terrain", 2, 1, with_water, []int{2, 0}, a) // water@(0,0), index 2
		new_bake := make([]Tile_Layer, 1, a)
		new_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a) // no "water"

		delta := tile_carry_delta(old_bake, live, a)
		testing.expect_value(t, len(delta.edits), 1)
		testing.expect_value(t, delta.edits[0].tile_name, "water")

		carried := tile_carry_apply(delta, new_bake, a)
		// "water" not in the new palette → dropped → the layer's cells share the
		// new bake's slice (no landed edit).
		testing.expect(t, raw_data(carried[0].cells) == raw_data(new_bake[0].cells))
		ver := World_Version {
			tilemaps = carried,
		}
		layer := version_tilemap(&ver, "terrain")
		testing.expect_value(t, tilemap_solid_at(layer, 0, 0), true) // stayed new-bake wall
	}

	// ===================================================================
	// ARM 4 (AC2): drop rule — a LAYER absent from the new artifact.
	// old_bake/live carry two layers (terrain, fog); SetTile floor@(0,0) on fog.
	// new_bake dropped the fog layer → fog's delta drops with it; terrain's own
	// edit still carries.
	// ===================================================================
	{
		old_bake := make([]Tile_Layer, 2, a)
		old_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a)
		old_bake[1] = tc_layer("fog", 2, 1, wall_floor, []int{0, 0}, a)
		live := make([]Tile_Layer, 2, a)
		live[0] = tc_layer("terrain", 2, 1, wall_floor, []int{1, 0}, a) // floor@(0,0) terrain
		live[1] = tc_layer("fog", 2, 1, wall_floor, []int{1, 0}, a) // floor@(0,0) fog
		new_bake := make([]Tile_Layer, 1, a)
		new_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a) // fog dropped

		delta := tile_carry_delta(old_bake, live, a)
		// Two edits in DECL ORDER: terrain first, then fog.
		testing.expect_value(t, len(delta.edits), 2)
		testing.expect_value(t, delta.edits[0].layer_name, "terrain")
		testing.expect_value(t, delta.edits[1].layer_name, "fog")

		carried := tile_carry_apply(delta, new_bake, a)
		testing.expect_value(t, len(carried), 1) // only terrain survives
		ver := World_Version {
			tilemaps = carried,
		}
		layer := version_tilemap(&ver, "terrain")
		// terrain's edit carried (floor@(0,0)); fog's edit dropped with the layer.
		testing.expect_value(t, tilemap_solid_at(layer, 0, 0), false)
		testing.expect(t, version_tilemap(&ver, "fog") == nil)
	}

	// ===================================================================
	// ARM 5 (AC2): a level edit in the reload SHOWS THROUGH where no delta
	// overrides it. old_bake "wall wall"; SetTile floor@(0,0) (live "floor wall").
	// new_bake recompiles the level with cell (1,0) changed to floor (a level
	// edit). carried: (0,0) from the delta = floor, (1,0) from the new bake = floor
	// — both visible.
	// ===================================================================
	{
		old_bake := make([]Tile_Layer, 1, a)
		old_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a)
		live := make([]Tile_Layer, 1, a)
		live[0] = tc_layer("terrain", 2, 1, wall_floor, []int{1, 0}, a) // SetTile floor@(0,0)
		new_bake := make([]Tile_Layer, 1, a)
		new_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 1}, a) // level edit: floor@(1,0)

		delta := tile_carry_delta(old_bake, live, a)
		testing.expect_value(t, len(delta.edits), 1)
		testing.expect_value(t, delta.edits[0].col, 0)

		carried := tile_carry_apply(delta, new_bake, a)
		ver := World_Version {
			tilemaps = carried,
		}
		layer := version_tilemap(&ver, "terrain")
		testing.expect_value(t, tilemap_solid_at(layer, 0, 0), false) // delta floor
		testing.expect_value(t, tilemap_solid_at(layer, 1, 0), false) // new-bake level-edit floor
	}

	// ===================================================================
	// ARM 6: a MAPPABLE delta over a NEW-BAKE edit on the SAME cell ⇒ delta
	// re-applies (delta wins the collision). old_bake "wall wall"; SetTile
	// floor@(0,0) (live "floor wall"). new_bake's level edit ALSO touched (0,0),
	// making it wall there (a no-op relative to old, but the new bake "owns" the
	// cell). The carried cell is the DELTA's floor — the drop rules govern only
	// UNmappable cells.
	// ===================================================================
	{
		old_bake := make([]Tile_Layer, 1, a)
		old_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a)
		live := make([]Tile_Layer, 1, a)
		live[0] = tc_layer("terrain", 2, 1, wall_floor, []int{1, 0}, a) // SetTile floor@(0,0)
		new_bake := make([]Tile_Layer, 1, a)
		new_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a) // new bake: wall@(0,0)

		delta := tile_carry_delta(old_bake, live, a)
		carried := tile_carry_apply(delta, new_bake, a)
		ver := World_Version {
			tilemaps = carried,
		}
		layer := version_tilemap(&ver, "terrain")
		// Collision on (0,0): delta floor WINS over the new bake's wall.
		testing.expect_value(t, tilemap_solid_at(layer, 0, 0), false)
	}

	// ===================================================================
	// ARM 7: EMPTY-DELTA reload ⇒ carried == new_bake structurally AND by
	// reference (structural sharing). live == old_bake (no SetTile ever ran) ⇒
	// empty delta ⇒ apply returns the new bake verbatim.
	// ===================================================================
	{
		old_bake := make([]Tile_Layer, 1, a)
		old_bake[0] = tc_layer("terrain", 2, 2, wall_floor, []int{0, 1, 1, 0}, a)
		live := make([]Tile_Layer, 1, a)
		live[0] = tc_layer("terrain", 2, 2, wall_floor, []int{0, 1, 1, 0}, a) // identical to old bake
		new_bake := make([]Tile_Layer, 1, a)
		new_bake[0] = tc_layer("terrain", 2, 2, wall_floor, []int{1, 1, 0, 0}, a) // a fresh recompile

		delta := tile_carry_delta(old_bake, live, a)
		testing.expect_value(t, len(delta.edits), 0)

		carried := tile_carry_apply(delta, new_bake, a)
		// Structural sharing: the no-op carry returns the new bake slice itself.
		testing.expect(t, raw_data(carried) == raw_data(new_bake))
		testing.expect(t, tile_layers_equal(carried[0], new_bake[0]))
	}

	// ===================================================================
	// ARM 8 (AC1, end-to-end over the wired swap path): the carry rides
	// migrate_world_version. With an EMPTY Migration_Set over a no-table world,
	// migrate_world_version threads (old bake, world.tilemaps, program bake)
	// through the carry — the production seam. old_bake "wall wall"; live
	// SetTile floor@(0,0); new program bake identical → the dug cell survives the
	// swap in the migrated version's tilemaps.
	// ===================================================================
	{
		old_bake := make([]Tile_Layer, 1, a)
		old_bake[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a)
		live := make([]Tile_Layer, 1, a)
		live[0] = tc_layer("terrain", 2, 1, wall_floor, []int{1, 0}, a) // SetTile floor@(0,0)
		new_program := Program {
			tilemaps = make([]Tile_Layer, 1, a),
		}
		new_program.tilemaps[0] = tc_layer("terrain", 2, 1, wall_floor, []int{0, 0}, a)

		world := World_Version {
			tick     = 7,
			tilemaps = live,
		}
		empty_set := Migration_Set{}
		// migrate_world_version takes the carry DELTA (the call site sources it):
		// diff the live committed layers against the old bake, then migrate re-bases
		// it onto the new program's bake.
		carry := tile_carry_delta(old_bake, world.tilemaps, a)
		migrated, refusal := migrate_world_version(empty_set, world, &new_program, carry, a)
		testing.expect_value(t, refusal.kind, Migrate_Refusal_Kind.None)
		testing.expect_value(t, migrated.tick, 7) // tick preserved
		layer := version_tilemap(&migrated, "terrain")
		testing.expect(t, layer != nil)
		// The dug cell survived the swap: floor@(0,0), non-solid.
		testing.expect_value(t, tilemap_solid_at(layer, 0, 0), false)
		testing.expect_value(t, tilemap_solid_at(layer, 1, 0), true) // untouched wall
	}
}

// --- sibling coverage (runs only under full `task test`, not the AC1/AC2 check) -

@(test)
test_reload_tile_multi_edit_order :: proc(t: ^testing.T) {
	// The delta scan is row-major within a layer and layer-decl order across
	// layers — pinned with multiple edits in one layer so the slice order is the
	// deterministic carry order (no map iteration).
	a := context.temp_allocator
	wall_floor := []Tile_Def{{name = "wall", solid = true}, {name = "floor", solid = false}}

	old_bake := make([]Tile_Layer, 1, a)
	old_bake[0] = tc_layer("terrain", 2, 2, wall_floor, []int{0, 0, 0, 0}, a)
	live := make([]Tile_Layer, 1, a)
	// SetTile floor at (1,0) [index 1] and (0,1) [index 2] — row-major order is
	// (1,0) before (0,1).
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
	// The carry is NAME-keyed, so a new palette that REORDERS the same names maps
	// the edit to the new index — index 1 ("floor") on the old side becomes index
	// 0 on the new side, and the carried cell resolves to floor regardless.
	a := context.temp_allocator
	old_pal := []Tile_Def{{name = "wall", solid = true}, {name = "floor", solid = false}}
	new_pal := []Tile_Def{{name = "floor", solid = false}, {name = "wall", solid = true}} // reshuffled

	old_bake := make([]Tile_Layer, 1, a)
	old_bake[0] = tc_layer("terrain", 2, 1, old_pal, []int{0, 0}, a)
	live := make([]Tile_Layer, 1, a)
	live[0] = tc_layer("terrain", 2, 1, old_pal, []int{1, 0}, a) // floor@(0,0), old index 1
	new_bake := make([]Tile_Layer, 1, a)
	new_bake[0] = tc_layer("terrain", 2, 1, new_pal, []int{1, 1}, a) // floor is index 0 here

	delta := tile_carry_delta(old_bake, live, a)
	testing.expect_value(t, delta.edits[0].tile_name, "floor")

	carried := tile_carry_apply(delta, new_bake, a)
	// The edit wrote the NEW palette's "floor" index (0), not the old (1).
	testing.expect_value(t, carried[0].cells[0], 0)
	ver := World_Version {
		tilemaps = carried,
	}
	layer := version_tilemap(&ver, "terrain")
	name, has := tilemap_tile_at(layer, 0, 0)
	testing.expect(t, has)
	testing.expect_value(t, name, "floor")
}
