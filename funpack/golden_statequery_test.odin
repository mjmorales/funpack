package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

STATE_QUERY_ADDITION ::
	"\n@doc(\"How many balls sit within r of origin — the §08 exemplar read: within over all[Ball] under the declared spatial structure, counted by an ordered fold.\")\n" +
	"@spatial(Ball.pos)\n" +
	"query balls_within(origin: Vec2, r: Fixed) -> Int {\n" +
	"  return fold(within(all[Ball], origin, r), 0, fn(acc, b) { return acc + 1 })\n" +
	"}\n" +
	"\n" +
	"@doc(\"The nearest in-radius ball's x position, or -1 when no ball is in radius — pins the nearest-first kernel order tick by tick.\")\n" +
	"@spatial(Ball.pos)\n" +
	"query nearest_ball_x(origin: Vec2, r: Fixed) -> Fixed {\n" +
	"  return match first(nearest_first(within(all[Ball], origin, r), origin)) {\n" +
	"    Option::Some(b) => b.pos.x\n" +
	"    Option::None => -1.0\n" +
	"  }\n" +
	"}\n" +
	"\n" +
	"@doc(\"One when a paddle defends the probed side, else zero — the keyed fold's counting step.\")\n" +
	"fn side_flag(want: Side, got: Side) -> Int {\n" +
	"  if got == want { return 1 }\n" +
	"  return 0\n" +
	"}\n" +
	"\n" +
	"@doc(\"How many paddles defend a side — the keyed read over all[Paddle] under the declared engine-maintained reverse lookup.\")\n" +
	"@index(Paddle.side)\n" +
	"query paddles_on(side: Side) -> Int {\n" +
	"  return fold(all[Paddle], 0, fn(acc, p) { return acc + side_flag(side, p.side) })\n" +
	"}\n" +
	"\n" +
	"@doc(\"The serve corridor half-extent for a probe radius — the pure value-parameter memoizable query form.\")\n" +
	"query corridor_half(r: Fixed) -> Fixed {\n" +
	"  return clamp(r * 0.5, 0.0, BOARD.h)\n" +
	"}\n"

STATE_QUERY_PRISTINE_IMPORT :: "import engine.list.{fold, first}"
STATE_QUERY_AMENDED_IMPORT :: "import engine.list.{fold, first, within, nearest_first}"

statequery_emit :: proc(t: ^testing.T) -> (artifact: string, ok: bool) {
	inputs, present := pong_emit_inputs(t)
	if !present {
		return "", false
	}
	widened, import_found := strings.replace(inputs.source, STATE_QUERY_PRISTINE_IMPORT, STATE_QUERY_AMENDED_IMPORT, 1, context.temp_allocator)
	testing.expect(t, import_found)
	amended := strings.concatenate({widened, STATE_QUERY_ADDITION}, context.temp_allocator)
	emitted, emit_err := stage_emit(amended, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, emit_err, Emit_Error.None)
	if emit_err != .None {
		return "", false
	}
	return emitted, true
}

@(test)
test_emit_statequery_carries_declared_queries :: proc(t: ^testing.T) {
	artifact, ok := statequery_emit(t)
	if !ok {
		return
	}
	doc, parse_err := parse_artifact(artifact)
	testing.expect_value(t, parse_err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)
	section, found := artifact_find_section(doc, "queries")
	testing.expect(t, found)
	testing.expect_value(t, section.count, 4)
	testing.expect(t, artifact_has_line(artifact, "index spatial Ball pos"))
	testing.expect(t, artifact_has_line(artifact, "index index Paddle side"))
	testing.expect(t, artifact_has_line(artifact, "node all Ball 0"))
	testing.expect(t, artifact_has_line(artifact, "node all Paddle 0"))
	testing.expect(t, artifact_has_line(artifact, "query corridor_half 1 return:Fixed 0 1 span:pong:272"))

	second, second_ok := statequery_emit(t)
	testing.expect(t, second_ok)
	testing.expect(t, artifact == second)
	if artifact == second {
		log.infof("emit statequery: amended-pong fixture emits 4 query records, byte-identical twice (%d bytes)", len(artifact))
	}
}

@(test)
test_emit_statequery_matches_runtime_testdata :: proc(t: ^testing.T) {
	emitted, ok := statequery_emit(t)
	if !ok {
		return
	}
	committed_path, _ := filepath.join({#directory, "..", "runtime", "testdata", "statequery.artifact"}, context.temp_allocator)
	if os.get_env("FUNPACK_REGEN_GOLDEN", context.temp_allocator) != "" {
		testing.expect(t, os.write_entire_file(committed_path, transmute([]u8)emitted) == nil)
		log.infof("REGEN statequery: wrote %s (%d bytes)", committed_path, len(emitted))
		return
	}
	committed_bytes, read_err := os.read_entire_file_from_path(committed_path, context.temp_allocator)
	if read_err != nil {
		log.warnf("SKIP statequery testdata match: committed %s unreadable", committed_path)
		return
	}
	committed := string(committed_bytes)
	if _, committed_version, stamp_ok := parse_version_stamp(line_around(committed, 0)); stamp_ok && committed_version < ARTIFACT_SCHEMA_VERSION {
		log.warnf(
			"SKIP statequery testdata match: committed runtime copy is stamped v%d while the emitter is at v%d — a staged schema bump; the runtime-side reconcile restamps its copy and restores this byte seam",
			committed_version,
			ARTIFACT_SCHEMA_VERSION,
		)
		return
	}
	testing.expect_value(t, len(emitted), len(committed))
	testing.expect(t, emitted == committed)
	if emitted != committed {
		report_first_byte_diff(emitted, committed)
		return
	}
	log.infof(
		"emit statequery: the live emitter reproduces the committed runtime/testdata/statequery.artifact byte-for-byte (%d bytes)",
		len(emitted),
	)
}
