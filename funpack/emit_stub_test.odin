package funpack

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

STUB_EMIT_SOURCE ::
	"@doc(\"Hole-first module: every executable surface stands on a typed hole.\")\n" +
	"\n" +
	"import engine.input.{Bindings}\n" +
	"\n" +
	"@doc(\"A stateful marker the holed behavior steps.\")\n" +
	"thing Ball {\n" +
	"  x: Fixed = 0.0\n" +
	"}\n" +
	"\n" +
	"@doc(\"A typecheck-only hole: callers compose against Fixed, dev execution fails closed.\")\n" +
	"fn hole_drag() -> Fixed @stub(Fixed)\n" +
	"\n" +
	"@doc(\"A live approximation: the fallback evaluates with the declaration's own params in scope.\")\n" +
	"fn hole_launch(boost: Fixed) -> Fixed @stub(Fixed, boost + 6.0)\n" +
	"\n" +
	"@doc(\"A pipelined holed step: the fallback echoes the entity so the loop stays playable.\")\n" +
	"behavior hole_nudge on Ball {\n" +
	"  fn step(self: Ball) -> Ball @stub(Ball, self)\n" +
	"}\n" +
	"\n" +
	"@doc(\"No device map — the minimal deviceless bindings.\")\n" +
	"fn bindings() -> Bindings {\n" +
	"  return Bindings.empty()\n" +
	"}\n" +
	"\n" +
	"@doc(\"The one-stage schedule carrying the holed behavior.\")\n" +
	"pipeline Loop {\n" +
	"  control: [hole_nudge]\n" +
	"}\n"

STUB_EMIT_ENTRYPOINT :: "use mini.{Loop, bindings}\n\nentrypoint main {\n  pipeline = Loop\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n"

stub_emit_artifact :: proc(t: ^testing.T) -> (artifact: string, ok: bool) {
	identity := Project_Identity{name = "mini", version = "0.1.0"}
	emitted, err := stage_emit(STUB_EMIT_SOURCE, "mini", identity, STUB_EMIT_ENTRYPOINT, context.temp_allocator)
	testing.expect_value(t, err, Emit_Error.None)
	if err != .None {
		return "", false
	}
	return emitted, true
}

@(test)
test_emit_stub_nodes_carry_holes :: proc(t: ^testing.T) {
	artifact, ok := stub_emit_artifact(t)
	if !ok {
		return
	}

	testing.expect(t, strings.has_prefix(artifact, "funpack-artifact 19\n"))
	doc, parse_err := parse_artifact(artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)

	testing.expect(t, strings.contains(artifact, "function hole_drag fn 0 return:Fixed 1 span:mini:11\nnode stub bare 0\n"))

	testing.expect(t, strings.contains(artifact,
		"function hole_launch fn 1 return:Fixed 1 span:mini:14\n" +
		"param boost Fixed\n" +
		"node stub fallback 1\n" +
		"node binary add 2\n" +
		"node name boost 0\n" +
		"node fixed 25769803776 0\n"))

	testing.expect(t, strings.contains(artifact,
		"behavior hole_nudge on:Ball stage:control contract:Update 0 1 1 1\n" +
		"param self Ball\n" +
		"emit Ball\n" +
		"node stub fallback 1\n" +
		"node name self 0\n"))
	log.infof("emit stub: bare and fallback holes serialize as v7 `stub` body nodes, pipelined hole included")
}

@(test)
test_emit_stub_double_emit_identical :: proc(t: ^testing.T) {
	first, first_ok := stub_emit_artifact(t)
	second, second_ok := stub_emit_artifact(t)
	if !first_ok || !second_ok {
		return
	}
	testing.expect(t, first == second)
}

@(test)
test_emit_stub_body_forest_well_formed :: proc(t: ^testing.T) {
	fallback_nodes := split_artifact_lines("node stub fallback 1\nnode name self 0\n")
	testing.expect(t, body_forest_is_well_formed(fallback_nodes, 1))
	bare_nodes := split_artifact_lines("node stub bare 0\n")
	testing.expect(t, body_forest_is_well_formed(bare_nodes, 1))
	truncated := split_artifact_lines("node stub fallback 1\n")
	testing.expect(t, !body_forest_is_well_formed(truncated, 1))
}

PIPELINED_HOLE_ADDITION ::
	"\n@doc(\"Hole fixture: the drift model under approximation — the fallback advances the ball so the loop stays playable while the real model is unwritten.\")\n" +
	"behavior hole_nudge on Ball {\n" +
	"  fn step(self: Ball, time: Time) -> Ball @stub(Ball, self with { pos: advance(self.pos, self.vel, time.dt) })\n" +
	"}\n" +
	"\n" +
	"@doc(\"Hole fixture: a bare typecheck-only hole alongside the pipelined one.\")\n" +
	"fn hole_drag() -> Fixed @stub(Fixed)\n"

PONG_COLLISION_STAGE_LINE :: "collision: [wall_bounce, paddle_bounce]"
PONG_COLLISION_STAGE_HOLED :: "collision: [wall_bounce, paddle_bounce, hole_nudge]"

amend_holed_pong_root :: proc(t: ^testing.T) -> (root: string, ok: bool) {
	copied: bool
	root, copied = copy_spec_tree_to_temp(resolve_pong_dir(), "pong-holes", "FUNPACK_PONG_DIR")
	if !copied {
		return "", false
	}
	if !append_scratch_tree_file(t, root, "src/pong.fun", PIPELINED_HOLE_ADDITION) {
		remove_scratch_tree(root)
		return "", false
	}
	src_path := scratch_join({root, "src", "pong.fun"})
	bytes, read_err := os.read_entire_file_from_path(src_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		remove_scratch_tree(root)
		return "", false
	}
	spliced, found := golden_variant(string(bytes), PONG_COLLISION_STAGE_LINE, PONG_COLLISION_STAGE_HOLED)
	testing.expect(t, found)
	if !found || !overwrite_scratch_tree_file(t, root, "src/pong.fun", spliced) {
		remove_scratch_tree(root)
		return "", false
	}
	return root, true
}

build_holed_pong_artifact :: proc(t: ^testing.T) -> (root: string, artifact: string, ok: bool) {
	amended: bool
	root, amended = amend_holed_pong_root(t)
	if !amended {
		return "", "", false
	}
	product, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		remove_scratch_tree(root)
		return "", "", false
	}
	write_err := write_build_products(product, root)
	testing.expect_value(t, write_err, Build_Write_Error.None)
	if write_err != .None {
		remove_scratch_tree(root)
		return "", "", false
	}
	artifact_bytes, read_err := os.read_entire_file_from_path(product.artifact_path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	if read_err != nil {
		remove_scratch_tree(root)
		return "", "", false
	}
	return root, string(artifact_bytes), true
}

@(test)
test_golden_holed_pong_artifact_carries_pipelined_fallback :: proc(t: ^testing.T) {
	root, artifact, ok := build_holed_pong_artifact(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	testing.expect(t, strings.has_prefix(artifact, "funpack-artifact 19\n"))
	doc, parse_err := parse_artifact(artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)

	testing.expect(t, strings.contains(artifact,
		"behavior hole_nudge on:Ball stage:collision contract:Update 0 2 1 1\n" +
		"param self Ball\n" +
		"param time Time\n" +
		"emit Ball\n" +
		"node stub fallback 1\n" +
		"node with 1 2\n" +
		"node name self 0\n" +
		"node recfield pos 1\n" +
		"node call 4\n" +
		"node name advance 0\n" +
		"node field pos 1\n" +
		"node name self 0\n" +
		"node field vel 1\n" +
		"node name self 0\n" +
		"node field dt 1\n" +
		"node name time 0\n"))

	testing.expect(t, strings.contains(artifact, "function hole_drag fn 0 return:Fixed 1 span:pong:"))
	testing.expect(t, strings.contains(artifact, "\nnode stub bare 0\n"))

	testing.expect(t, strings.contains(artifact, " stage:collision behavior:hole_nudge\n"))
	log.infof("golden holed pong: the pipelined fallback hole and the bare hole both reach the written artifact as v7 stub bodies")
}

@(test)
test_golden_holed_pong_double_build_identical :: proc(t: ^testing.T) {
	root, first, ok := build_holed_pong_artifact(t)
	if !ok {
		return
	}
	defer remove_scratch_tree(root)

	product, verdict := stage_build(root, .Dev, context.temp_allocator)
	testing.expect_value(t, verdict.err, Build_Error.None)
	if verdict.err != .None {
		return
	}
	testing.expect_value(t, len(product.artifact), len(first))
	testing.expect(t, product.artifact == first)
}
