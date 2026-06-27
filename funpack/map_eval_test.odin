package funpack

import "core:strings"
import "core:testing"

MAP_EVAL_HEADER :: "import engine.map.{Map, empty, len, get, has, set, remove, keys, values}\n"

expect_map_test :: proc(t: ^testing.T, body: string, decls := "") {
	source := strings.concatenate(
		{MAP_EVAL_HEADER, decls, "test \"map\" {\n", body, "\n}\n"},
		context.temp_allocator,
	)
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.failed, 0)
	testing.expect(t, report.passed > 0)
}

@(test)
test_map_set_get_roundtrip :: proc(t: ^testing.T) {
	expect_map_test(t, "  assert empty().set(1, true).get(1) == Option::Some(true)")
	expect_map_test(t, "  assert empty().set(1, true).get(2) == Option::None")
}

@(test)
test_map_has_membership :: proc(t: ^testing.T) {
	expect_map_test(t, "  assert empty().set(1, true).has(1) == true")
	expect_map_test(t, "  assert empty().set(1, true).has(2) == false")
}

@(test)
test_map_set_replaces_in_place :: proc(t: ^testing.T) {
	expect_map_test(
		t,
		"  let m = empty().set(1, true).set(1, false)\n" +
		"  assert m.len() == 1\n" +
		"  assert m.get(1) == Option::Some(false)\n" +
		"  assert m.keys() == [1]",
	)
}

@(test)
test_map_remove_closes_gap :: proc(t: ^testing.T) {
	expect_map_test(
		t,
		"  let m = empty().set(1, true).set(2, false).remove(1)\n" +
		"  assert m.keys() == [2]\n" +
		"  assert m.len() == 1\n" +
		"  assert empty().set(1, true).remove(9).keys() == [1]",
	)
}

@(test)
test_map_keys_values_insertion_order :: proc(t: ^testing.T) {
	expect_map_test(
		t,
		"  let m = empty().set(2, false).set(1, true)\n" +
		"  assert m.keys() == [2, 1]\n" +
		"  assert m.values() == [false, true]\n" +
		"  assert (m.keys() == [1, 2]) == false",
	)
}

@(test)
test_map_equality_is_positional :: proc(t: ^testing.T) {
	expect_map_test(
		t,
		"  assert empty().set(1, true).set(2, false) == empty().set(1, true).set(2, false)\n" +
		"  assert (empty().set(1, true).set(2, false) == empty().set(2, false).set(1, true)) == false",
	)
}

@(test)
test_map_empty_static_form_evaluates :: proc(t: ^testing.T) {
	expect_map_test(t, "  assert Map.empty().set(1, true).get(1) == Option::Some(true)")
	expect_map_test(t, "  assert Map.empty().len() == 0")
}

@(test)
test_map_cell_tile_keyed_state :: proc(t: ^testing.T) {
	expect_map_test(
		t,
		"  let floor = empty().set(Cell{x: 0, y: 0}, Tile::Wall).set(Cell{x: 1, y: 0}, Tile::Floor)\n" +
		"  assert floor.get(Cell{x: 0, y: 0}) == Option::Some(Tile::Wall)\n" +
		"  assert floor.get(Cell{x: 1, y: 0}) == Option::Some(Tile::Floor)\n" +
		"  assert floor.get(Cell{x: 9, y: 9}) == Option::None\n" +
		"  assert floor.has(Cell{x: 0, y: 0}) == true\n" +
		"  assert floor.len() == 2",
		"import engine.grid.{Cell}\nenum Tile { Floor, Wall }\n",
	)
}
