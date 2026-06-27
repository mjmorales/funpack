package funpack

import "core:strings"
import "core:testing"

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
	err := typecheck_buildlayer(
		"fn build(map: TilemapHandle) -> [BuildLayer] {\n" +
		"  return [BuildLayer{map: map, fill: \"floor\", cells: [(Cell{x: 1, y: 1}, \"wall\")]}]\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_buildlayer_empty_cells_types :: proc(t: ^testing.T) {
	err := typecheck_buildlayer(
		"fn build(map: TilemapHandle) -> [BuildLayer] {\n" +
		"  return [BuildLayer{map: map, fill: \"floor\", cells: []}]\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.None)
}

@(test)
test_buildlayer_behavior_emit_types :: proc(t: ^testing.T) {
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
	err := typecheck_buildlayer(
		"fn bad(map: TilemapHandle) -> [BuildLayer] {\n" +
		"  return [BuildLayer{map: map, fill: \"floor\", cells: [], seed: 3}]\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_buildlayer_rejects_non_string_fill :: proc(t: ^testing.T) {
	err := typecheck_buildlayer(
		"fn bad(map: TilemapHandle) -> [BuildLayer] {\n" +
		"  return [BuildLayer{map: map, fill: 4, cells: []}]\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_buildlayer_rejects_non_handle_map :: proc(t: ^testing.T) {
	err := typecheck_buildlayer(
		"fn bad() -> [BuildLayer] {\n" +
		"  return [BuildLayer{map: 1.0, fill: \"floor\", cells: []}]\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

@(test)
test_buildlayer_rejects_non_string_cell_tile :: proc(t: ^testing.T) {
	err := typecheck_buildlayer(
		"fn bad(map: TilemapHandle) -> [BuildLayer] {\n" +
		"  return [BuildLayer{map: map, fill: \"floor\", cells: [(Cell{x: 0, y: 0}, 7)]}]\n" +
		"}\n")
	testing.expect_value(t, err, Type_Error.Type_Mismatch)
}

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

BUILDLAYER_EMIT_ENTRYPOINT :: "use mini.{GenLayer, bindings}\n\nentrypoint main {\n  pipeline = GenLayer\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n"

@(test)
test_buildlayer_behavior_contract_and_emission :: proc(t: ^testing.T) {
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

	second, second_err := stage_emit(BUILDLAYER_EMIT_SOURCE, "mini", identity, BUILDLAYER_EMIT_ENTRYPOINT, context.temp_allocator)
	testing.expect_value(t, second_err, Emit_Error.None)
	testing.expect_value(t, artifact, second)
}
