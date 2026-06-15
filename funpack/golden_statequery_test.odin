// The §08 §3 state-query END-TO-END fixture's emission side: one project tree
// declaring @index/@spatial queries, compiled by the production emitter, whose
// artifact the runtime acceptance golden (runtime/statequery_acceptance_test.odin)
// #loads to pin index maintenance and query results per tick.
//
// FIXTURE TECHNIQUE — the amended-scratch producer-real mold (the probes /
// expr-holes goldens' precedent): NO COMMITTED SPEC EXAMPLE declares a query
// or an @index/@spatial directive yet — none of the nine golden projects
// exercises the §08 §3 surface, a MISSING-ACCEPTANCE-EXAMPLE GAP for the
// operator to close in the in-repo spec — so the fixture is the live PONG tree
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
// source — the SPEC-TRUE §08 §3 read shape: every query takes only value
// parameters and reads the world through `all[T]` and the spatial
// combinators (the View-parameter interim form is retired — it is now the
// named Query_Param_Not_Value diagnostic). Two @spatial(Ball.pos) queries
// pin the radius read and the nearest-first kernel order, an
// @index(Paddle.side) query pins the keyed read over all[Paddle], and
// corridor_half stays the pure value-parameter memoizable form. The names
// share no substring with any pristine pong decl.
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

// The addendum's bodies read the §08 §3 spatial combinators, which pong's
// pristine import line does not bind — the pre-build amendment widens that
// ONE import member group (the same amended-scratch technique as the source
// append: a developer edit before the build, never a doctored artifact).
STATE_QUERY_PRISTINE_IMPORT :: "import engine.list.{fold, first}"
STATE_QUERY_AMENDED_IMPORT :: "import engine.list.{fold, first, within, nearest_first}"

// statequery_emit builds the amended fixture through the production emitter:
// the live pong tree's emit inputs with the addendum appended to the source —
// the pre-build amendment seam, so the artifact is a real emitter product over
// the amended tree. ok = false on the golden SKIP (absent checkout).
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

// test_emit_statequery_carries_declared_queries pins the [queries] surface the
// runtime acceptance consumes: four records in source order, each requirement
// line naming its (KIND, THING, FIELD), the `all` world-read nodes the v10
// bodies carry, and a well-formed artifact whose every section count
// reconciles under the funpack reader. Double-emit pins determinism (spec §29).
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
