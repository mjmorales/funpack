package funpack

import "core:testing"

@(test)
test_capstone_dungeon_floor_keyed_tile_lookup :: proc(t: ^testing.T) {
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
