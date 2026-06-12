// The §18 §4 BuildLayer command ADMISSION fixtures: the whole-layer twin of
// SetTile. A seeded generation behavior's `BuildLayer{map, fill, cells}`
// construction typechecks against the closed surface schema (map:
// TilemapHandle, fill: String, cells: [(Cell, String)]), a `-> [BuildLayer]`
// Update behavior clears the §06 §6 contract gate (the [Spawn]-class command-out
// form), and the construction lowers through stage_emit as the generic
// `record BuildLayer 3 3` node forest with the behavior's `emit [BuildLayer]`
// line — the same path Spawn and SetTile ride. The `cells` list-of-tuple field
// types like SetTile's `cell` extended to a list: the tuple's first position is
// the structural Cell (no checker ground, the grid_cells discipline), the second
// the String tile name. The negative fixtures pin the closed schema: an unknown
// field, a non-String fill, a non-handle map, and a wrong-typed cells row each
// reject. Self-contained (no golden checkout); the runtime-side application
// fixtures live in the SEPARATE runtime-honor task, not here.
package funpack

import "core:strings"
import "core:testing"

// BUILDLAYER_HEADER declares the minimal generation-shaped surface: the
// engine.tilemap row's handle + BuildLayer command imports, the user's own Cell
// record (the grid_cells discipline — engine.grid owns no Cell ground), and a
// Gen thing the behavior steps on.
BUILDLAYER_HEADER :: "import engine.math.{Fixed, Vec2}\n" +
	"import engine.tilemap.{TilemapHandle, BuildLayer}\n" +
	"data Cell { x: Int, y: Int }\n" +
	"thing Gen { t: Fixed = 0.0 }\n"

typecheck_buildlayer :: proc(body: string) -> Type_Error {
	source := strings.concatenate({BUILDLAYER_HEADER, body}, context.temp_allocator)
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return .Unsupported_Expr
	}
	_, err := stage_typecheck(ast)
	return err
}

@(test)
test_buildlayer_construction_types :: proc(t: ^testing.T) {
	// AC (BuildLayer{map, fill, cells}): the generation spelling — a handle off a
	// param, a String base tile, and a list of (cell, tile-name) override tuples
	// — checks clean against the closed surface schema, and the constructed list
	// unifies with the `-> [BuildLayer]` return.
	err := typecheck_buildlayer(
		"fn build(map: TilemapHandle) -> [BuildLayer] {\n" +
		"  return [BuildLayer{map: map, fill: \"floor\", cells: [(Cell{x: 1, y: 1}, \"wall\")]}]\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_buildlayer_empty_cells_types :: proc(t: ^testing.T) {
	// AC (an all-fill layer): the explicit-override list may be empty — a pure
	// fill with no overrides typechecks (the empty list unifies against the
	// [(Cell, String)] element type).
	err := typecheck_buildlayer(
		"fn build(map: TilemapHandle) -> [BuildLayer] {\n" +
		"  return [BuildLayer{map: map, fill: \"floor\", cells: []}]\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_buildlayer_behavior_emit_types :: proc(t: ^testing.T) {
	// AC (the command-out behavior form): an Update behavior whose step returns
	// `[BuildLayer]` typechecks — the literal handle stands in for the level
	// seam's layer constant, multiple override rows ride the cells list.
	err := typecheck_buildlayer(
		"behavior gen on Gen {\n" +
		"  fn step(self: Gen) -> [BuildLayer] {\n" +
		"    return [BuildLayer{map: TilemapHandle{name: \"terrain\"}, fill: \"floor\", cells: [(Cell{x: 0, y: 0}, \"wall\"), (Cell{x: 1, y: 0}, \"water\")]}]\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_buildlayer_rejects_unknown_field :: proc(t: ^testing.T) {
	// The schema is closed: a field outside {map, fill, cells} rejects — never a
	// silently-dropped extra column.
	err := typecheck_buildlayer(
		"fn bad(map: TilemapHandle) -> [BuildLayer] {\n" +
		"  return [BuildLayer{map: map, fill: \"floor\", cells: [], seed: 3}]\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_buildlayer_rejects_non_string_fill :: proc(t: ^testing.T) {
	// `fill` names the base palette tile — a String, never a palette index
	// (names, not numbers: the §18 §2 legibility discipline, SetTile's `tile`).
	err := typecheck_buildlayer(
		"fn bad(map: TilemapHandle) -> [BuildLayer] {\n" +
		"  return [BuildLayer{map: map, fill: 4, cells: []}]\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_buildlayer_rejects_non_handle_map :: proc(t: ^testing.T) {
	// `map` is the level seam's TilemapHandle — a Fixed scalar rejects.
	err := typecheck_buildlayer(
		"fn bad() -> [BuildLayer] {\n" +
		"  return [BuildLayer{map: 1.0, fill: \"floor\", cells: []}]\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_buildlayer_rejects_non_string_cell_tile :: proc(t: ^testing.T) {
	// The `cells` row is (Cell, String): the override's tile name is a String,
	// so a numeric tile in the second tuple position rejects against the
	// list-of-tuple schema.
	err := typecheck_buildlayer(
		"fn bad(map: TilemapHandle) -> [BuildLayer] {\n" +
		"  return [BuildLayer{map: map, fill: \"floor\", cells: [(Cell{x: 0, y: 0}, 7)]}]\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

// BUILDLAYER_EMIT_SOURCE is the minimal pipelined module the emission fixture
// serializes: a control-stage gen behavior returning a one-command [BuildLayer]
// list, plus the deviceless bindings the entrypoint wires.
BUILDLAYER_EMIT_SOURCE :: "import engine.input.{Bindings}\n" +
	"import engine.tilemap.{TilemapHandle, BuildLayer}\n" +
	"data Cell { x: Int, y: Int }\n" +
	"thing Gen { t: Fixed = 0.0 }\n" +
	"behavior gen on Gen {\n" +
	"  fn step(self: Gen) -> [BuildLayer] {\n" +
	"    return [BuildLayer{map: TilemapHandle{name: \"terrain\"}, fill: \"floor\", cells: [(Cell{x: 1, y: 1}, \"wall\")]}]\n" +
	"  }\n" +
	"}\n" +
	"fn bindings() -> Bindings {\n" +
	"  return Bindings.empty()\n" +
	"}\n" +
	"pipeline GenLayer {\n" +
	"  control: [gen]\n" +
	"}\n"

// BUILDLAYER_EMIT_ENTRYPOINT wires the fixture's pipeline and bindings — the
// write_minimal_valid_tree shape the SetTile emission fixture uses.
BUILDLAYER_EMIT_ENTRYPOINT :: "use mini.{GenLayer, bindings}\n\nentrypoint main {\n  pipeline = GenLayer\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n"

@(test)
test_buildlayer_behavior_contract_and_emission :: proc(t: ^testing.T) {
	// AC (contract + artifact carry, the Spawn mold end-to-end): the pipelined
	// gen behavior clears the full checked pipeline (the Update contract admits
	// the [BuildLayer] command-out), and the emitted artifact carries the
	// behavior's `emit [BuildLayer]` line plus the construction as the generic
	// record forest — `record BuildLayer 3 3` with one recfield per schema field
	// in source order — parsing well-formed under the funpack reader.
	identity := Project_Identity{name = "mini", version = "0.1.0"}
	artifact, err := stage_emit(BUILDLAYER_EMIT_SOURCE, "mini", identity, BUILDLAYER_EMIT_ENTRYPOINT, context.temp_allocator)
	testing.expect_value(t, err, Emit_Error.None)
	if err != .None {
		return
	}

	testing.expect(t, strings.contains(artifact, "behavior gen on:Gen stage:control contract:Update"))
	testing.expect(t, strings.contains(artifact, "emit [BuildLayer]\n"))
	testing.expect(t, strings.contains(artifact, "node record BuildLayer 3 3\n"))
	testing.expect(t, strings.contains(artifact, "node recfield map 1\n"))
	testing.expect(t, strings.contains(artifact, "node recfield fill 1\n"))
	testing.expect(t, strings.contains(artifact, "node recfield cells 1\n"))

	doc, parse_err := parse_artifact(artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)

	// Emission is a pure function of its inputs — two calls, identical bytes.
	second, second_err := stage_emit(BUILDLAYER_EMIT_SOURCE, "mini", identity, BUILDLAYER_EMIT_ENTRYPOINT, context.temp_allocator)
	testing.expect_value(t, second_err, Emit_Error.None)
	testing.expect_value(t, artifact, second)
}
