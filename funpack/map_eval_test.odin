package funpack

import "core:strings"
import "core:testing"

// The engine.map compiler-evaluator layer: the eight methods evaluated end-to-end
// through the funpack `test` verb (run_test_pipeline runs eval, not just typing).
// These pin the insertion-ordered semantics the decision fixes — set
// replaces-in-place, remove closes the gap, keys/values project in insertion
// order, equality is positional — plus the canonical Map[Cell, Tile] keyed state.

// MAP_EVAL_HEADER imports the full engine.map surface for the eval fixtures.
MAP_EVAL_HEADER :: "import engine.map.{Map, empty, len, get, has, set, remove, keys, values}\n"

// expect_map_test runs a test block over the engine.map import header and asserts
// every assertion in it passed — the eval-fixture harness for the map semantics.
// report.passed counts ASSERTS (a block with N asserts passes N), so this checks
// no assert failed and at least one ran.
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
	// AC: set then get round-trips — a key bound to a value reads back Some(value),
	// and a missing key reads None (total lookup).
	expect_map_test(t, "  assert empty().set(1, true).get(1) == Option::Some(true)")
	expect_map_test(t, "  assert empty().set(1, true).get(2) == Option::None")
}

@(test)
test_map_has_membership :: proc(t: ^testing.T) {
	// AC: has is the membership predicate — true for a present key, false for an
	// absent one.
	expect_map_test(t, "  assert empty().set(1, true).has(1) == true")
	expect_map_test(t, "  assert empty().set(1, true).has(2) == false")
}

@(test)
test_map_set_replaces_in_place :: proc(t: ^testing.T) {
	// AC: re-setting an existing key updates its value WITHOUT growing the map or
	// moving the key — len stays 1, get reads the latest value, the single key keeps
	// its position.
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
	// AC: remove drops the key and closes the gap, preserving insertion order among
	// the rest; removing an absent key leaves the map unchanged (total).
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
	// AC: keys() and values() project in INSERTION order, not sorted-by-key — set(2)
	// before set(1) yields keys [2, 1], and values pair positionally with keys.
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
	// AC: two maps are equal iff they carry the same pairs in the same insertion
	// order — same order equal, the same entries in a different order NOT equal (the
	// List equality model the decision pins).
	expect_map_test(
		t,
		"  assert empty().set(1, true).set(2, false) == empty().set(1, true).set(2, false)\n" +
		"  assert (empty().set(1, true).set(2, false) == empty().set(2, false).set(1, true)) == false",
	)
}

@(test)
test_map_empty_static_form_evaluates :: proc(t: ^testing.T) {
	// AC: the idiomatic `Map.empty()` static constructor evaluates to the same empty
	// map the bare `empty()` does — both build onto the same insertion-ordered value.
	expect_map_test(t, "  assert Map.empty().set(1, true).get(1) == Option::Some(true)")
	expect_map_test(t, "  assert Map.empty().len() == 0")
}

@(test)
test_map_cell_tile_keyed_state :: proc(t: ^testing.T) {
	// AC: the decision's canonical case — a Map[Cell, Tile] over the engine.grid Cell
	// record key and a user Tile enum value. A record key uses structural equality
	// (value_equal), so Cell{x:0,y:0} reads back its tile and a different cell reads
	// None. This is the keyed-state shape the friction report (data Floor { tiles:
	// Map[Cell, Tile] }) exists for.
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
