// The §18 §4 SetTile command ADMISSION fixtures: the dungeon's dig-shaped
// `SetTile{map, cell, tile}` construction typechecks against the closed
// surface schema (map: TilemapHandle, cell: the user's Cell record, tile:
// String), a `-> [SetTile]` Update behavior clears the §06 §6 contract gate
// (the [Spawn]-class command-out form), and the construction lowers through
// stage_emit as the generic `record SetTile 3 3` node forest with the
// behavior's `emit [SetTile]` line — the same path Spawn rides. The negative
// fixtures pin the closed schema: an unknown field, a non-String tile, and a
// non-handle map each reject. Self-contained (no golden checkout); the
// runtime-side application fixtures live in runtime/settile_test.odin.
package funpack

import "core:strings"
import "core:testing"

// SETTILE_HEADER declares the minimal dig-shaped surface: the engine.tilemap
// row's handle + command imports, the user's own Cell record (the grid_cells
// discipline — engine.grid owns no Cell ground), and a Digger thing the
// behavior steps on.
SETTILE_HEADER :: "import engine.math.{Fixed, Vec2}\n" +
	"import engine.tilemap.{TilemapHandle, SetTile}\n" +
	"data Cell { x: Int, y: Int }\n" +
	"thing Digger { t: Fixed = 0.0 }\n"

typecheck_settile :: proc(body: string) -> Type_Error {
	source := strings.concatenate({SETTILE_HEADER, body}, context.temp_allocator)
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return .Unsupported_Expr
	}
	_, err := stage_typecheck(ast)
	return err
}

@(test)
test_settile_construction_types :: proc(t: ^testing.T) {
	// AC (SetTile{map, cell, tile}): the dungeon's dig spelling — a handle off
	// a param, a user Cell record, a String tile name — checks clean against
	// the closed surface schema, and the constructed list unifies with the
	// `-> [SetTile]` return.
	err := typecheck_settile(
		"fn carve(map: TilemapHandle, target: Cell) -> [SetTile] {\n" +
		"  return [SetTile{map: map, cell: target, tile: \"floor\"}]\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_settile_behavior_emit_types :: proc(t: ^testing.T) {
	// AC (the command-out behavior form): an Update behavior whose step
	// returns `[SetTile]` typechecks — the literal handle stands in for the
	// level seam's layer constant.
	err := typecheck_settile(
		"behavior dig on Digger {\n" +
		"  fn step(self: Digger) -> [SetTile] {\n" +
		"    return [SetTile{map: TilemapHandle{name: \"terrain\"}, cell: Cell{x: 1, y: 1}, tile: \"floor\"}]\n" +
		"  }\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_settile_rejects_unknown_field :: proc(t: ^testing.T) {
	// The schema is closed: a field outside {map, cell, tile} rejects — never
	// a silently-dropped extra column.
	err := typecheck_settile(
		"fn bad(map: TilemapHandle) -> [SetTile] {\n" +
		"  return [SetTile{map: map, cell: Cell{x: 0, y: 0}, tile: \"floor\", force: 3}]\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_settile_rejects_non_string_tile :: proc(t: ^testing.T) {
	// `tile` names a palette tile — a String, never a palette index (names,
	// not numbers: the §18 §2 legibility discipline).
	err := typecheck_settile(
		"fn bad(map: TilemapHandle) -> [SetTile] {\n" +
		"  return [SetTile{map: map, cell: Cell{x: 0, y: 0}, tile: 4}]\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_settile_rejects_non_handle_map :: proc(t: ^testing.T) {
	// `map` is the level seam's TilemapHandle — a Fixed scalar rejects.
	err := typecheck_settile(
		"fn bad(target: Cell) -> [SetTile] {\n" +
		"  return [SetTile{map: 1.0, cell: target, tile: \"floor\"}]\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

// SETTILE_EMIT_SOURCE is the minimal pipelined module the emission fixture
// serializes: a control-stage dig behavior returning a one-command [SetTile]
// list, plus the deviceless bindings the entrypoint wires.
SETTILE_EMIT_SOURCE :: "import engine.input.{Bindings}\n" +
	"import engine.tilemap.{TilemapHandle, SetTile}\n" +
	"data Cell { x: Int, y: Int }\n" +
	"thing Digger { t: Fixed = 0.0 }\n" +
	"behavior dig on Digger {\n" +
	"  fn step(self: Digger) -> [SetTile] {\n" +
	"    return [SetTile{map: TilemapHandle{name: \"terrain\"}, cell: Cell{x: 1, y: 1}, tile: \"floor\"}]\n" +
	"  }\n" +
	"}\n" +
	"fn bindings() -> Bindings {\n" +
	"  return Bindings.empty()\n" +
	"}\n" +
	"pipeline Dig {\n" +
	"  control: [dig]\n" +
	"}\n"

// SETTILE_EMIT_ENTRYPOINT wires the fixture's pipeline and bindings — the
// write_minimal_valid_tree shape the stub emission fixture uses.
SETTILE_EMIT_ENTRYPOINT :: "use mini.{Dig, bindings}\n\nentrypoint main {\n  pipeline = Dig\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n"

@(test)
test_settile_behavior_contract_and_emission :: proc(t: ^testing.T) {
	// AC (contract + artifact carry, the Spawn mold end-to-end): the pipelined
	// dig behavior clears the full checked pipeline (the Update contract
	// admits the [SetTile] command-out), and the emitted artifact carries the
	// behavior's `emit [SetTile]` line plus the construction as the generic
	// record forest — `record SetTile 3 3` with one recfield per schema field
	// in source order — parsing well-formed under the funpack reader.
	identity := Project_Identity{name = "mini", version = "0.1.0"}
	artifact, err := stage_emit(SETTILE_EMIT_SOURCE, "mini", identity, SETTILE_EMIT_ENTRYPOINT, context.temp_allocator)
	testing.expect_value(t, err, Emit_Error.None)
	if err != .None {
		return
	}

	testing.expect(t, strings.contains(artifact, "behavior dig on:Digger stage:control contract:Update"))
	testing.expect(t, strings.contains(artifact, "emit [SetTile]\n"))
	testing.expect(t, strings.contains(artifact, "node record SetTile 3 3\n"))
	testing.expect(t, strings.contains(artifact, "node recfield map 1\n"))
	testing.expect(t, strings.contains(artifact, "node recfield cell 1\n"))
	testing.expect(t, strings.contains(artifact, "node recfield tile 1\n"))

	doc, parse_err := parse_artifact(artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)

	// Emission is a pure function of its inputs — two calls, identical bytes.
	second, second_err := stage_emit(SETTILE_EMIT_SOURCE, "mini", identity, SETTILE_EMIT_ENTRYPOINT, context.temp_allocator)
	testing.expect_value(t, second_err, Emit_Error.None)
	testing.expect_value(t, artifact, second)
}
