// The §08 §3 state-query END-TO-END fixture's emission side: one project tree
// declaring @index/@spatial queries, compiled by the production emitter, whose
// artifact the runtime acceptance golden (runtime/statequery_acceptance_test.odin)
// #loads to pin index maintenance and query results per tick.
//
// FIXTURE TECHNIQUE — the amended-scratch producer-real mold (the probes /
// expr-holes goldens' precedent): NO COMMITTED SPEC EXAMPLE declares a query
// or an @index/@spatial directive yet — none of the nine golden projects
// exercises the §08 §3 surface, a MISSING-ACCEPTANCE-EXAMPLE GAP for the
// operator to close in funpack-spec — so the fixture is the live PONG tree
// with the STATE_QUERY_ADDITION appended BEFORE the build, and every asserted
// byte is what funpack really wrote over the amended tree, never a doctored
// product. Pong is the base deliberately: it is query-free, single-module,
// and its Ball.pos (a moving Vec2) and Paddle.side (a keyed variant) are
// exactly the two column shapes the directive pair wants. When a spec example
// authors queries, these pins move to the pristine tree. Like the other
// goldens it resolves the sibling checkout (or FUNPACK_PONG_DIR) and SKIPs
// loudly when absent — a skipped golden is a warning, never a pass.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// STATE_QUERY_ADDITION is the query addendum appended to the copied pong
// source: two counting helpers, a @spatial query over Ball.pos and an @index
// query over Paddle.side (both reading the world through an explicit View[T]
// parameter — the compiler does not yet admit the spec's `all[T]` read form,
// so the View parameter is the compilable §08 read surface, stated in the
// runtime's query_eval.odin header), and a pure value-parameter query (the
// memoizable form). The names share no substring with any pristine pong decl.
STATE_QUERY_ADDITION ::
	"\n@doc(\"One when a point lies within r of origin by squared fixed-point distance, else zero — the query fold's counting step.\")\n" +
	"fn within_flag(origin: Vec2, r: Fixed, at: Vec2) -> Int {\n" +
	"  let d = at - origin\n" +
	"  if d.x * d.x + d.y * d.y <= r * r { return 1 }\n" +
	"  return 0\n" +
	"}\n" +
	"\n" +
	"@doc(\"One when a paddle defends the probed side, else zero — the keyed fold's counting step.\")\n" +
	"fn side_flag(want: Side, got: Side) -> Int {\n" +
	"  if got == want { return 1 }\n" +
	"  return 0\n" +
	"}\n" +
	"\n" +
	"@doc(\"How many balls sit within a radius of an origin. Declares the engine-maintained spatial structure over Ball.pos.\")\n" +
	"@spatial(Ball.pos)\n" +
	"query balls_within(origin: Vec2, r: Fixed, balls: View[Ball]) -> Int {\n" +
	"  return fold(balls, 0, fn(acc, b) { return acc + within_flag(origin, r, b.pos) })\n" +
	"}\n" +
	"\n" +
	"@doc(\"How many paddles defend a side. Declares the engine-maintained keyed reverse lookup over Paddle.side.\")\n" +
	"@index(Paddle.side)\n" +
	"query paddles_on(side: Side, paddles: View[Paddle]) -> Int {\n" +
	"  return fold(paddles, 0, fn(acc, p) { return acc + side_flag(side, p.side) })\n" +
	"}\n" +
	"\n" +
	"@doc(\"The serve corridor half-extent for a probe radius — the pure value-parameter memoizable query form.\")\n" +
	"query corridor_half(r: Fixed) -> Fixed {\n" +
	"  return clamp(r * 0.5, 0.0, BOARD.h)\n" +
	"}\n"

// statequery_emit builds the amended fixture through the production emitter:
// the live pong tree's emit inputs with the addendum appended to the source —
// the pre-build amendment seam, so the artifact is a real emitter product over
// the amended tree. ok = false on the golden SKIP (absent checkout).
statequery_emit :: proc(t: ^testing.T) -> (artifact: string, ok: bool) {
	inputs, present := pong_emit_inputs(t)
	if !present {
		return "", false
	}
	amended := strings.concatenate({inputs.source, STATE_QUERY_ADDITION}, context.temp_allocator)
	emitted, emit_err := stage_emit(amended, inputs.module, inputs.project, inputs.entrypoint_fcfg, context.temp_allocator)
	testing.expect_value(t, emit_err, Emit_Error.None)
	if emit_err != .None {
		return "", false
	}
	return emitted, true
}

// test_emit_statequery_carries_declared_queries pins the [queries] surface the
// runtime acceptance consumes: three records in source order, each requirement
// line naming its (KIND, THING, FIELD), and a well-formed v9 artifact whose
// every section count reconciles under the funpack reader. Double-emit pins
// determinism (spec §29).
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
	testing.expect_value(t, section.count, 3)
	testing.expect(t, artifact_has_line(artifact, "index spatial Ball pos"))
	testing.expect(t, artifact_has_line(artifact, "index index Paddle side"))
	testing.expect(t, artifact_has_line(artifact, "query corridor_half 1 return:Fixed 0 1 span:pong:270"))

	second, second_ok := statequery_emit(t)
	testing.expect(t, second_ok)
	testing.expect(t, artifact == second)
	if artifact == second {
		log.infof("emit statequery: amended-pong fixture emits 3 query records, byte-identical twice (%d bytes)", len(artifact))
	}
}

// test_emit_statequery_matches_runtime_testdata is the cross-package byte seam
// (the krognid emit golden's mold): the freshly-emitted fixture equals the
// committed runtime/testdata/statequery.artifact the runtime acceptance #loads,
// byte-for-byte. FUNPACK_REGEN_GOLDEN=1 rewrites the committed copy from the
// live emission (the operator-gated regen path); a normal run only compares. A
// staged schema bump SKIPs loudly (committed stamp trailing the emitter's); a
// SAME-version divergence is the staleness this seam exists to catch.
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
