package funpack

import "core:testing"

// Capstone for the engine.map umbrella (friction 54f69693, decision
// 2026-06-25-engine-map-insertion-ordered): the EXACT shape the friction report
// could not express — a record with a Map[Cell, Tile] field and a keyed lookup with
// an Option fallback — now typechecks AND evaluates end-to-end. This ties together the
// type model, the engine.map module, the get method, and the or_else fallback the
// report's `tile_at` used. (The record is `Dungeon`, not the report's `Floor`, only to
// avoid a name clash with the `Tile::Floor` variant; the keyed-tile-map shape is the
// report's verbatim.)

@(test)
test_capstone_dungeon_floor_keyed_tile_lookup :: proc(t: ^testing.T) {
	// AC: the friction repro resolves and runs — `import engine.map.{Map}` binds, a
	// `tiles: Map[Cell, Tile]` field resolves, `dungeon.tiles.get(c)` reads Option[Tile]
	// off the stored map, and `or_else(..., Tile::Wall)` falls back for an unstored
	// cell. A stored cell reads its tile; an unstored cell reads the Wall fallback.
	source :=
		"import engine.map.{Map, empty, get, set}\n" +
		"import engine.grid.{Cell}\n" +
		"import engine.prelude.{or_else}\n" +
		"enum Tile { Floor, Wall, Stairs }\n" +
		"data Dungeon { tiles: Map[Cell, Tile] }\n" +
		"fn tile_at(dungeon: Dungeon, c: Cell) -> Tile {\n" +
		"  return or_else(dungeon.tiles.get(c), Tile::Wall)\n" +
		"}\n" +
		"test \"dungeon floor keyed tile lookup\" {\n" +
		"  let dungeon = Dungeon{tiles: empty().set(Cell{x: 1, y: 2}, Tile::Stairs)}\n" +
		"  assert tile_at(dungeon, Cell{x: 1, y: 2}) == Tile::Stairs\n" +
		"  assert tile_at(dungeon, Cell{x: 9, y: 9}) == Tile::Wall\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.failed, 0)
	testing.expect(t, report.passed > 0)
}
