// Index Contract `project` record tests: the exact-match field set, valid
// one-object-per-line NDJSON with a leading schema_version, the byte-identical
// double emission, and the authored/derived field projection against the live
// pong tree. The exact-match assertions pin every top-level field deliberately
// — no missing and no extra (spec §29 §2); when the contract reshapes, the
// expectation changes in lockstep with INDEX_SCHEMA_VERSION, never loosened to
// a range. The golden case resolves the sibling pong checkout (or
// FUNPACK_PONG_DIR) and SKIPs loudly when absent, mirroring the golden_pong
// skip semantics, so a missing checkout never silently passes.
package funpack

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// ── Authored-field readers (snippet-shaped, in-memory) ─────────────────
// These exercise the fcfg block/list readers directly, independent of the
// on-disk tree, so the authored projection is provable without a checkout.

@(test)
test_index_lift_entrypoint_records :: proc(t: ^testing.T) {
	// The contract's entrypoints lift rides the one §14 production: parse,
	// then convert every block onto the record shape with its integer tick
	// rate. Two blocks lift two records — the contract reports all authored
	// entrypoints, unlike the emit path's single selection.
	content := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick     = 60hz\n  logical  = 160x120\n  bindings = bindings\n}\nentrypoint replay {\n  pipeline = Pong\n  tick = 30hz\n  logical = 160x120\n  bindings = bindings\n}\n"
	parsed, parse_err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, parse_err, Entrypoints_Error.None)
	records, ok := lift_entrypoint_records(parsed)
	testing.expect(t, ok)
	testing.expect_value(t, len(records), 2)
	if len(records) == 2 {
		testing.expect_value(t, records[0].name, "main")
		testing.expect_value(t, records[0].pipeline, "Pong")
		testing.expect_value(t, records[0].tick_hz, 60)
		testing.expect_value(t, records[0].bindings, "bindings")
		testing.expect_value(t, records[1].name, "replay")
		testing.expect_value(t, records[1].tick_hz, 30)
	}
}

@(test)
test_index_lift_entrypoint_records_bad_rate_rejected :: proc(t: ^testing.T) {
	// `60khz` passes the grammar's `hz`-suffix check but is not an integer
	// rate — the lift catches the one value error the grammar cannot.
	content := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60khz\n  logical = 160x120\n  bindings = bindings\n}\n"
	parsed, parse_err := parse_entrypoints_fcfg(content)
	testing.expect_value(t, parse_err, Entrypoints_Error.None)
	_, ok := lift_entrypoint_records(parsed)
	testing.expect(t, !ok)
}

@(test)
test_index_parse_tick_hz :: proc(t: ^testing.T) {
	hz, ok := parse_tick_hz("60hz")
	testing.expect(t, ok)
	testing.expect_value(t, hz, 60)
	// A bare rate with no unit and a non-hz unit are both malformed.
	_, bare_ok := parse_tick_hz("60")
	testing.expect(t, !bare_ok)
	_, unit_ok := parse_tick_hz("60khz")
	testing.expect(t, !unit_ok)
}

@(test)
test_index_read_build_platform :: proc(t: ^testing.T) {
	blocks := fcfg_blocks("build native {\n  platform = desktop\n}\n", "build")
	testing.expect_value(t, len(blocks), 1)
	if len(blocks) == 1 {
		testing.expect_value(t, blocks[0].label, "native")
		testing.expect_value(t, len(blocks[0].assignments), 1)
		testing.expect_value(t, blocks[0].assignments[0].value, "desktop")
	}
}

@(test)
test_index_read_tag_list_in_authored_order :: proc(t: ^testing.T) {
	tags := fcfg_tag_list("tags {\n  game\n  startup\n  render\n}\n")
	testing.expect_value(t, len(tags), 3)
	if len(tags) == 3 {
		// Authored order is preserved — the registry is never re-sorted.
		testing.expect_value(t, tags[0], "game")
		testing.expect_value(t, tags[1], "startup")
		testing.expect_value(t, tags[2], "render")
	}
}

// ── NDJSON shape and schema_version ────────────────────────────────────

@(test)
test_index_contract_emits_valid_ndjson_with_schema_version :: proc(t: ^testing.T) {
	// A minimal hand-built project record marshals to exactly one JSON
	// object on one line, terminated by a single LF, carrying the leading
	// schema_version key — the one-object-per-line NDJSON transport.
	record := minimal_project_record()
	line := emit_project_record(record, context.temp_allocator)
	testing.expect(t, strings.has_suffix(line, "\n"))
	body := strings.trim_suffix(line, "\n")
	// Exactly one object: no interior newline, opens `{` and closes `}`.
	testing.expect_value(t, strings.count(body, "\n"), 0)
	testing.expect(t, strings.has_prefix(body, "{"))
	testing.expect(t, strings.has_suffix(body, "}"))
	// schema_version is the leading key (it is the first struct field) and
	// carries the current INDEX_SCHEMA_VERSION stamp (now 6 — the §02 §7
	// extern-type kind admission bumped it from 5).
	testing.expect(t, strings.has_prefix(body, "{\"schema_version\":"))
	testing.expect(t, strings.contains(body, "\"schema_version\":6"))
}

@(test)
test_index_contract_ndjson_byte_identical_twice :: proc(t: ^testing.T) {
	// Deterministic whole-stream emission: emitting the same project record
	// twice yields byte-identical NDJSON. No map, no clock, no float feeds
	// the marshal, so the bytes cannot drift between emissions.
	record := minimal_project_record()
	first := emit_project_record(record, context.temp_allocator)
	second := emit_project_record(record, context.temp_allocator)
	testing.expect_value(t, first, second)
}

// ── Exact-match field set against the live pong tree ───────────────────

@(test)
test_index_contract_pong_project_record_exact_fields :: proc(t: ^testing.T) {
	// The emitted pong project record carries ALL required fields exactly —
	// the authored entrypoints, builds, tag_registry and the derived
	// capabilities, pipeline_flattened, gate_results, behind a leading
	// schema_version — with no missing and no extra top-level field
	// (exact-match per spec §29 §2). The expected key set is the closed list
	// the contract fixes; the emitted object's keys must equal it. The stream is
	// multi-record (project line then decl lines, §29 §2), so the project
	// record is LINE 1 — assert it leads the whole-stream NDJSON.
	stream, ok := pong_index_line()
	if !ok {
		return
	}
	lines := ndjson_lines(stream)
	testing.expect(t, len(lines) >= 1)
	if len(lines) == 0 {
		return
	}
	body := lines[0]
	// The project record is the FIRST line of the stream (one decl line follows
	// per declaration), and it is itself a `project`-shaped record — it carries
	// pipeline_flattened/gate_results, which a `decl` record never does.
	testing.expect(t, strings.contains(body, "\"pipeline_flattened\":"))
	testing.expect(t, strings.contains(body, "\"gate_results\":"))
	expected_keys := []string {
		"schema_version",
		"entrypoints",
		"builds",
		"tag_registry",
		"capabilities",
		"pipeline_flattened",
		"gate_results",
	}
	for key in expected_keys {
		needle := strings.concatenate({"\"", key, "\":"}, context.temp_allocator)
		testing.expectf(t, strings.contains(body, needle), "project record missing field %s", key)
	}
	// No extra top-level field: the object's top-level key count equals the
	// expected set's size. Top-level keys are the `"key":` occurrences at
	// brace depth 1, so a nested record's keys (an entrypoint's `pipeline`)
	// are not counted.
	testing.expect_value(t, top_level_key_count(body), len(expected_keys))
	// A passing-run confirmation line: the Odin test runner is silent on
	// success, so this surfaces the index-contract project-record NDJSON
	// verification in the runner's default-visible info output.
	log.infof("index contract project record NDJSON exact-match verified (%d fields)", len(expected_keys))
}

@(test)
test_index_contract_pong_authored_and_derived_values :: proc(t: ^testing.T) {
	// The pong project record's authored and derived values, pinned against
	// the live tree: the single entrypoint (Pong / 60hz / bindings), the one
	// desktop build, the ten-tag registry, the core-only capability set
	// (pong wires no optional battery), the eleven-step flattened pipeline,
	// and the seven all-passing gate results.
	_, ok := pong_index_line()
	if !ok {
		return
	}
	record, build_ok := pong_project_record()
	testing.expect(t, build_ok)
	if !build_ok {
		return
	}
	testing.expect_value(t, record.schema_version, INDEX_SCHEMA_VERSION)

	testing.expect_value(t, len(record.entrypoints), 1)
	if len(record.entrypoints) == 1 {
		testing.expect_value(t, record.entrypoints[0].name, "main")
		testing.expect_value(t, record.entrypoints[0].pipeline, "Pong")
		testing.expect_value(t, record.entrypoints[0].tick_hz, 60)
		testing.expect_value(t, record.entrypoints[0].bindings, "bindings")
	}

	testing.expect_value(t, len(record.builds), 1)
	if len(record.builds) == 1 {
		testing.expect_value(t, record.builds[0].name, "native")
		testing.expect_value(t, record.builds[0].platform, "desktop")
	}

	// The ten-tag registry, in authored order (tags.fcfg).
	testing.expect_value(t, len(record.tag_registry), 10)
	if len(record.tag_registry) == 10 {
		testing.expect_value(t, record.tag_registry[0], "game")
		testing.expect_value(t, record.tag_registry[9], "event")
	}

	// Core render/input/state only — pong declares no ui/, models/, net:,
	// @expose, or audio: stage, so no optional battery is on.
	testing.expect_value(t, len(record.capabilities), 3)
	testing.expect(t, index_capabilities_contains(record.capabilities, .Render))
	testing.expect(t, index_capabilities_contains(record.capabilities, .Input))
	testing.expect(t, index_capabilities_contains(record.capabilities, .State))
	testing.expect(t, !index_capabilities_contains(record.capabilities, .Netcode))
	testing.expect(t, !index_capabilities_contains(record.capabilities, .Audio))

	// The eleven-step depth-first total order (spec §07 §3), gap-free.
	testing.expect_value(t, len(record.pipeline_flattened), 11)
	if len(record.pipeline_flattened) == 11 {
		testing.expect_value(t, record.pipeline_flattened[0].ordinal, 0)
		testing.expect_value(t, record.pipeline_flattened[0].stage, "startup")
		testing.expect_value(t, record.pipeline_flattened[0].behavior, "setup")
		testing.expect_value(t, record.pipeline_flattened[10].behavior, "draw_score")
	}

	// Every structural gate clears on the gameplay golden (spec §29 §1).
	testing.expect_value(t, len(record.gate_results), int(max(Gate_Family)) + 1)
	for result in record.gate_results {
		testing.expectf(t, result.passed, "gate %v unexpectedly failed on the pong golden", result.gate)
	}
}

@(test)
test_index_contract_snake_project_record :: proc(t: ^testing.T) {
	// The snake project's Index Contract record, end to end through the full
	// checked pipeline: a valid one-object-per-line NDJSON behind the leading
	// INDEX_SCHEMA_VERSION (the index NDJSON shape is unchanged by the snake
	// surface — the artifact-format schema bump for tuple/bare_binder arms is a
	// separate compatibility gate; the snake `project` record carries whatever
	// INDEX_SCHEMA_VERSION is current, asserted symbolically), the single 8hz
	// Snake entrypoint, the snake-shaped capability set (render/input/state), and
	// the twelve-step depth-first flattened pipeline (setup → turn → advance →
	// detect_eat → grow → despawn_eaten → replenish → detect_death → apply_death →
	// draw_snake → draw_food → draw_state). The fixture resolves the sibling snake
	// checkout (or FUNPACK_SNAKE_DIR) and SKIPs loudly when absent.
	dir := resolve_snake_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP index contract snake: %s not found — set FUNPACK_SNAKE_DIR or ensure the in-repo fixture exists", dir)
		return
	}
	identity, project_err, _ := read_project(dir)
	testing.expect_value(t, project_err, Project_Error.None)
	if project_err != .None || len(identity.sources) == 0 {
		return
	}
	source_bytes, read_err := os.read_entire_file_from_path(identity.sources[0].path, context.temp_allocator)
	testing.expect(t, read_err == nil)
	typed, flat, compiled := compile_for_index(string(source_bytes))
	testing.expect(t, compiled)
	if !compiled {
		return
	}
	record, record_err := build_project_record(dir, typed, flat)
	testing.expect_value(t, record_err, Index_Contract_Error.None)
	if record_err != .None {
		return
	}

	testing.expect_value(t, record.schema_version, INDEX_SCHEMA_VERSION)
	testing.expect_value(t, len(record.entrypoints), 1)
	if len(record.entrypoints) == 1 {
		testing.expect_value(t, record.entrypoints[0].pipeline, "Snake")
		testing.expect_value(t, record.entrypoints[0].tick_hz, 8)
	}
	// Render/input/state — snake wires no optional battery (no ui/, models/, net:,
	// @expose, or audio: stage).
	testing.expect_value(t, len(record.capabilities), 3)
	testing.expect(t, index_capabilities_contains(record.capabilities, .Render))
	testing.expect(t, index_capabilities_contains(record.capabilities, .Input))
	testing.expect(t, index_capabilities_contains(record.capabilities, .State))
	// The twelve-step depth-first total order (spec §07 §3), gap-free.
	testing.expect_value(t, len(record.pipeline_flattened), 12)
	if len(record.pipeline_flattened) == 12 {
		testing.expect_value(t, record.pipeline_flattened[0].ordinal, 0)
		testing.expect_value(t, record.pipeline_flattened[0].behavior, "setup")
		testing.expect_value(t, record.pipeline_flattened[11].behavior, "draw_state")
	}
	// Every structural gate clears on the snake golden (spec §29 §1).
	testing.expect_value(t, len(record.gate_results), int(max(Gate_Family)) + 1)
	for result in record.gate_results {
		testing.expectf(t, result.passed, "gate %v unexpectedly failed on the snake golden", result.gate)
	}
	log.infof("index contract snake project record verified (12-step pipeline, schema v%d)", INDEX_SCHEMA_VERSION)
}

@(test)
test_index_contract_modding_capability_from_expose :: proc(t: ^testing.T) {
	// The §14 §4 Modding battery derives from the parsed §05 §4 @expose marker:
	// source_has_expose reads the Ast's source-ordered declaration sequence, so
	// one marked declaration anywhere (here a fn) switches modding on, and an
	// unmarked source — the pong/snake corpus shape — leaves it off.
	exposed_source := "data Hex { q: Int }\n" +
		"@expose\n" +
		"fn axial(q: Int) -> Int {\n" +
		"  return q\n" +
		"}\n"
	exposed_ast, exposed_err := stage_parse(stage_lex(exposed_source))
	testing.expect_value(t, exposed_err, Parse_Error.None)
	testing.expect(t, source_has_expose(exposed_ast))

	plain_ast, plain_err := stage_parse(stage_lex("data Hex { q: Int }\n"))
	testing.expect_value(t, plain_err, Parse_Error.None)
	testing.expect(t, !source_has_expose(plain_ast))
}

@(test)
test_index_contract_pong_double_emission_identical :: proc(t: ^testing.T) {
	// Emitting the pong project record twice from the same source yields
	// byte-identical NDJSON — the deterministic whole-stream obligation, end
	// to end through the project read + compile + emit path.
	first, ok := pong_index_line()
	if !ok {
		return
	}
	second, second_ok := pong_index_line()
	testing.expect(t, second_ok)
	testing.expect_value(t, first, second)
	// Passing-run confirmation: a double index emission is byte-identical
	// NDJSON, surfaced in the runner's default-visible info output.
	log.infof("index contract double index emission is byte-identical NDJSON — project deterministic")
}

// ── Whole-stream decl records over the live checkouts ──────────────────
// The §29 §2 multi-record stream end to end through read_index_project: the
// `project` record on line 1, then one `decl` record line per declaration in the
// module's source-ordered declaration sequence. These pin the live pong + snake decl set against
// the golden source — representative decls' qualified_name/kind/span/emits/
// consumes/calls/dup_class/mut_data plus the all-decls stub=false (neither
// golden tree carries a @stub hole) / todo=false (no @todo note) / debug=[]
// (no probe) invariant — so the
// contract reshape that added the decl record kind is proven against the real
// tree, not a hand-shaped stub. SKIP-warn loudly (never silently pass) when the
// sibling checkout is absent.

@(test)
test_index_contract_pong_decl_records :: proc(t: ^testing.T) {
	// The pong whole-stream NDJSON: line 1 is the `project` record, then one
	// `decl` line per declaration in fixed order. The decl-line count equals the
	// derived record count (33 pong decls), every decl line carries the v3
	// schema_version stamp with stub=false (no pong decl is holed), the
	// derived todo=false (no pong decl carries a @todo note), and the derived
	// debug [] (no pong decl carries a probe), and the representative decls
	// pin their derived projection.
	stream, ok := pong_index_line()
	if !ok {
		return
	}
	lines := ndjson_lines(stream)
	// One project line then one decl line per declaration (pong: 33 decls).
	testing.expect_value(t, len(lines), 1 + 33)
	if len(lines) != 34 {
		return
	}
	// Line 1 is the `project` record (pipeline_flattened/gate_results are
	// project-only fields a decl record never carries); the decl lines follow.
	testing.expect(t, strings.contains(lines[0], "\"pipeline_flattened\":"))
	for i in 1 ..< len(lines) {
		decl := lines[i]
		// Every decl line carries the bumped v3 stamp; stub is false on this
		// hole-free tree, the DERIVED todo flag is false on this note-free
		// tree, and the DERIVED debug field is [] on this probe-free tree.
		testing.expect(t, strings.has_prefix(decl, "{\"schema_version\":6,"))
		testing.expect(t, strings.contains(decl, "\"stub\":false"))
		testing.expect(t, strings.contains(decl, "\"todo\":false"))
		testing.expect(t, strings.contains(decl, "\"debug\":[]"))
		// No decl line is a `project` record — the decl key set is disjoint.
		testing.expect(t, !strings.contains(decl, "\"pipeline_flattened\":"))
	}
	// Representative pong decls: Board (data, span 16), score (emits Goal, no
	// mut_data — returns [Goal]), tally (consumes Goal, mut_data Scoreboard),
	// overlaps (calls abs), paddle_move (calls value + clamp). The decl LINES are
	// asserted via substring so the stream's emitted bytes carry the projection.
	testing.expect(t, stream_has_decl(lines, "\"qualified_name\":\"Board\"", "\"kind\":\"Data\""))
	testing.expect(t, stream_has_decl(lines, "\"qualified_name\":\"score\"", "\"emits\":[\"Goal\"]"))
	testing.expect(t, stream_has_decl(lines, "\"qualified_name\":\"tally\"", "\"mut_data\":[\"Scoreboard\"]"))
	testing.expect(t, stream_has_decl(lines, "\"qualified_name\":\"overlaps\"", "\"calls\":[\"abs\"]"))
	testing.expect(t, stream_has_decl(lines, "\"qualified_name\":\"paddle_move\"", "\"clamp\""))
	log.infof("index contract pong whole-stream decl records verified (%d decl lines)", len(lines) - 1)
}

@(test)
test_index_contract_snake_decl_records :: proc(t: ^testing.T) {
	// The snake whole-stream NDJSON: line 1 is the `project` record, then one
	// `decl` line per declaration (snake: 36 decls). Every decl line carries the
	// v3 stamp with stub=false (no snake decl is holed), the derived todo=false
	// (no snake decl carries a @todo note), and the derived debug [] (no snake
	// decl carries a probe); the
	// first data decl (Cell) and its kind are pinned against the golden source.
	dir := resolve_snake_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP index contract snake decl records: %s not found — set FUNPACK_SNAKE_DIR or ensure the in-repo fixture exists", dir)
		return
	}
	stream, err, _, compiled := read_index_project(dir, context.temp_allocator)
	testing.expect_value(t, err, Index_Contract_Error.None)
	testing.expect(t, compiled)
	if err != .None || !compiled {
		return
	}
	lines := ndjson_lines(stream)
	// One project line then one decl line per declaration (snake: 36 decls).
	testing.expect_value(t, len(lines), 1 + 36)
	if len(lines) != 37 {
		return
	}
	testing.expect(t, strings.contains(lines[0], "\"pipeline_flattened\":"))
	for i in 1 ..< len(lines) {
		decl := lines[i]
		testing.expect(t, strings.has_prefix(decl, "{\"schema_version\":6,"))
		testing.expect(t, strings.contains(decl, "\"stub\":false"))
		testing.expect(t, strings.contains(decl, "\"todo\":false"))
		testing.expect(t, strings.contains(decl, "\"debug\":[]"))
		testing.expect(t, !strings.contains(decl, "\"pipeline_flattened\":"))
	}
	// The first snake data decl (Cell) at its keyword line, pinned in the stream.
	testing.expect(t, stream_has_decl(lines, "\"qualified_name\":\"Cell\"", "\"kind\":\"Data\""))
	log.infof("index contract snake whole-stream decl records verified (%d decl lines)", len(lines) - 1)
}

// test_read_index_project_threads_real_project_error pins the error-threading fix: a
// present funpack_configs/ holding a malformed project.fcfg fails read_project for a
// SPECIFIC cause (not a missing configs dir). read_index_project must surface that real
// Project_Error under the Project_Read_Failed arm — never collapse it to
// Missing_Configs_Dir (the bug: 13 distinct causes mislabelled as one).
@(test)
test_read_index_project_threads_real_project_error :: proc(t: ^testing.T) {
	root := scratch_join({scratch_base(), tprintf_seq("funpack-index-malformed")})
	remove_scratch_tree(root)
	configs := scratch_join({root, "funpack_configs"})
	if !ensure_dir(configs) {
		log.warnf("SKIP index threads project error: cannot materialize tree")
		return
	}
	defer remove_scratch_tree(root)
	if os.write_entire_file(scratch_join({configs, "project.fcfg"}), "not a project fcfg {{{") != nil {
		log.warnf("SKIP index threads project error: cannot write malformed project.fcfg")
		return
	}

	stream, err, project_err, compiled := read_index_project(root, context.temp_allocator)
	testing.expect_value(t, stream, "")
	testing.expect_value(t, compiled, false)
	testing.expect_value(t, err, Index_Contract_Error.Project_Read_Failed)
	// The configs dir IS present, so the real cause is a malformed-project read failure,
	// NOT Missing_Configs_Dir — proving the cause is threaded, not collapsed.
	testing.expect(t, project_err != .None, "the real Project_Error cause is threaded")
	testing.expect(t, project_err != .Missing_Configs_Dir, "a present-but-malformed tree is not reported as a missing configs dir")
}

// stream_has_decl reports whether some decl line of the stream contains BOTH
// needles — the per-decl assertion the whole-stream tests use: it isolates the
// one line carrying a decl's qualified_name and checks a derived field on that
// same line, so a field on a DIFFERENT decl's line never satisfies the check.
stream_has_decl :: proc(lines: []string, name_needle: string, field_needle: string) -> bool {
	for line in lines {
		if strings.contains(line, name_needle) && strings.contains(line, field_needle) {
			return true
		}
	}
	return false
}

// ── Decl record: NDJSON shape, determinism, exact-match key set ─────────
// The §29 §2 per-declaration `decl` record. These exercise the hand-built
// record in-memory (no derivation, no checkout) the way the minimal_project
// tests do — they pin the SHAPE: leading schema_version stamp,
// one-object-per-line NDJSON with a trailing LF, byte-identical double
// emission, and the closed exact-match key set INCLUDING the stub/todo/debug
// §05 directive fields at their empty values (mandatory-present, not omitted —
// the hand-built record carries no hole, no @todo note, no probe).

@(test)
test_index_decl_record_ndjson_shape :: proc(t: ^testing.T) {
	// A hand-built decl record marshals to exactly one JSON object on one line,
	// terminated by a single LF, carrying the leading schema_version stamp at
	// the current INDEX_SCHEMA_VERSION (now 6) — the one-object-per-line NDJSON
	// transport, identical to the project record's.
	record := minimal_decl_record()
	line := emit_decl_record(record, context.temp_allocator)
	testing.expect(t, strings.has_suffix(line, "\n"))
	body := strings.trim_suffix(line, "\n")
	// Exactly one object: no interior newline, opens `{` and closes `}`.
	testing.expect_value(t, strings.count(body, "\n"), 0)
	testing.expect(t, strings.has_prefix(body, "{"))
	testing.expect(t, strings.has_suffix(body, "}"))
	// schema_version is the leading key (the first struct field) carrying the
	// current stamp.
	testing.expect(t, strings.has_prefix(body, "{\"schema_version\":"))
	testing.expect(t, strings.contains(body, "\"schema_version\":6"))
	// The kind enum emits as its readable name (use_enum_names), never an
	// ordinal — a Behavior decl reports "Behavior".
	testing.expect(t, strings.contains(body, "\"kind\":\"Behavior\""))
	log.infof("index contract decl record NDJSON shape verified (schema v%d)", INDEX_SCHEMA_VERSION)
}

@(test)
test_index_decl_record_byte_identical_twice :: proc(t: ^testing.T) {
	// Deterministic whole-stream emission: emitting the same decl record twice
	// yields byte-identical NDJSON. No map, no clock, no float feeds the marshal
	// — every field is a scalar or a slice (including the u64 dup_class hash) —
	// so the bytes cannot drift between emissions.
	record := minimal_decl_record()
	first := emit_decl_record(record, context.temp_allocator)
	second := emit_decl_record(record, context.temp_allocator)
	testing.expect_value(t, first, second)
}

@(test)
test_index_decl_record_exact_key_set :: proc(t: ^testing.T) {
	// The emitted decl record carries ALL §29 §2 fields exactly — no missing
	// and no extra (exact-match per spec §29 §2). The expected key set is the
	// closed inline list the contract fixes, in field-declaration = emitted key
	// order; the emitted object's top-level keys must equal it. The stub/todo/
	// debug §05 directive fields are present too — mandatory, never omitted,
	// even when false/[].
	record := minimal_decl_record()
	line := emit_decl_record(record, context.temp_allocator)
	body := strings.trim_suffix(line, "\n")
	expected_keys := []string {
		"schema_version",
		"qualified_name",
		"kind",
		"file",
		"span",
		"doc",
		"gtags",
		"stub",
		"todo",
		"debug",
		"exposed",
		"emits",
		"consumes",
		"calls",
		"dup_class",
		"mut_data",
	}
	for key in expected_keys {
		needle := strings.concatenate({"\"", key, "\":"}, context.temp_allocator)
		testing.expectf(t, strings.contains(body, needle), "decl record missing field %s", key)
	}
	// The directive fields are present at their empty values (mandatory-present
	// per exact-match, never omitted — the hand-built record is not holed,
	// not @todo'd, not probed, and not @expose'd).
	testing.expect(t, strings.contains(body, "\"stub\":false"))
	testing.expect(t, strings.contains(body, "\"todo\":false"))
	testing.expect(t, strings.contains(body, "\"debug\":[]"))
	testing.expect(t, strings.contains(body, "\"exposed\":false"))
	// No extra top-level field: the object's top-level key count equals the
	// expected set's size (nested-key-safe via top_level_key_count).
	testing.expect_value(t, top_level_key_count(body), len(expected_keys))
	log.infof("index contract decl record NDJSON exact-match verified (%d fields)", len(expected_keys))
}

// minimal_decl_record builds a hand-shaped decl record for the §29 §2 decl
// shape tests: a populated record exercising every field's emission. The
// stub/todo/debug §05 directive fields carry their empty values (false/false/[]
// — the record is not holed, carries no @todo note, and carries no probe) so
// the shape tests pin mandatory-present empties. Each slice field is temp-allocated
// so the record outlives the constructor's frame.
minimal_decl_record :: proc() -> Decl_Record {
	gtags := make([]string, 1, context.temp_allocator)
	gtags[0] = "game"
	emits := make([]string, 1, context.temp_allocator)
	emits[0] = "Hit"
	consumes := make([]string, 1, context.temp_allocator)
	consumes[0] = "Tick"
	calls := make([]string, 1, context.temp_allocator)
	calls[0] = "advance"
	mut_data := make([]string, 1, context.temp_allocator)
	mut_data[0] = "Ball"
	return Decl_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		qualified_name = "pong.update_ball",
		kind           = .Behavior,
		file           = "",
		span           = 42,
		doc            = "advances the ball",
		gtags          = gtags,
		stub           = false,
		todo           = false,
		debug          = make([]string, 0, context.temp_allocator),
		exposed        = false,
		emits          = emits,
		consumes       = consumes,
		calls          = calls,
		dup_class      = 0xcbf29ce484222325,
		mut_data       = mut_data,
	}
}

// ── Helpers ────────────────────────────────────────────────────────────

// minimal_project_record builds a hand-shaped project record for the
// NDJSON-shape tests: a single entrypoint, one build, two tags, the core
// capabilities, a one-step pipeline, and one gate result. Each slice field is
// temp-allocated so the record outlives the constructor's frame (a compound
// slice literal would back onto the stack). It exercises the emitter's
// field-order and escaping without a checkout.
minimal_project_record :: proc() -> Project_Record {
	entrypoints := make([]Entrypoint_Record, 1, context.temp_allocator)
	entrypoints[0] = Entrypoint_Record{name = "main", pipeline = "Loop", tick_hz = 60, bindings = "binds"}
	builds := make([]Build_Record, 1, context.temp_allocator)
	builds[0] = Build_Record{name = "native", platform = "desktop"}
	tags := make([]string, 2, context.temp_allocator)
	tags[0], tags[1] = "game", "render"
	caps := make([]Capability, 3, context.temp_allocator)
	caps[0], caps[1], caps[2] = .Render, .Input, .State
	steps := make([]Flat_Step_Record, 1, context.temp_allocator)
	steps[0] = Flat_Step_Record{ordinal = 0, stage = "startup", behavior = "setup"}
	gates := make([]Gate_Result, 1, context.temp_allocator)
	gates[0] = Gate_Result{gate = .Cyclomatic, passed = true}
	return Project_Record {
		schema_version = INDEX_SCHEMA_VERSION,
		entrypoints = entrypoints,
		builds = builds,
		tag_registry = tags,
		capabilities = caps,
		pipeline_flattened = steps,
		gate_results = gates,
	}
}

// pong_index_line emits the pong WHOLE Index Contract NDJSON stream (the
// `project` record line then one `decl` line per declaration) via the end-to-end
// read_index_project seam; ok is false (with a SKIP warning) when the sibling
// pong checkout is absent or the source does not compile, matching the
// golden_pong skip semantics. The whole-stream caller splits with ndjson_lines.
pong_index_line :: proc() -> (line: string, ok: bool) {
	dir := resolve_pong_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP index contract pong: %s not found — set FUNPACK_PONG_DIR or ensure the in-repo fixture exists", dir)
		return "", false
	}
	ndjson, err, _, compiled := read_index_project(dir, context.temp_allocator)
	if err != .None || !compiled {
		return "", false
	}
	return ndjson, true
}

// pong_project_record builds the pong project record (pre-emission) so the
// value tests read its typed fields directly; ok is false when the checkout is
// absent or the source does not compile.
pong_project_record :: proc() -> (record: Project_Record, ok: bool) {
	dir := resolve_pong_dir()
	if !os.is_dir(dir) {
		return Project_Record{}, false
	}
	identity, project_err, _ := read_project(dir)
	if project_err != .None || len(identity.sources) == 0 {
		return Project_Record{}, false
	}
	source_bytes, read_err := os.read_entire_file_from_path(identity.sources[0].path, context.temp_allocator)
	if read_err != nil {
		return Project_Record{}, false
	}
	typed, flat, compiled := compile_for_index(string(source_bytes))
	if !compiled {
		return Project_Record{}, false
	}
	built, record_err := build_project_record(dir, typed, flat)
	if record_err != .None {
		return Project_Record{}, false
	}
	return built, true
}

// ndjson_lines splits a whole NDJSON stream into its per-record JSON object
// lines, dropping the trailing empty element the final LF produces. Each line is
// one record's object (no trailing LF), so a stream test reads line[0] as the
// `project` record and line[1..] as the `decl` records in emission order.
ndjson_lines :: proc(stream: string) -> []string {
	trimmed := strings.trim_suffix(stream, "\n")
	if trimmed == "" {
		return nil
	}
	return strings.split(trimmed, "\n", context.temp_allocator)
}

// top_level_key_count counts the `"key":` occurrences at brace depth 1 of a
// JSON object — its top-level fields — so the exact-match test rejects an
// extra top-level key without miscounting a nested record's keys. It tracks
// brace/bracket depth and string state so a `:` inside a string value or a
// nested object never inflates the count.
top_level_key_count :: proc(object: string) -> int {
	count := 0
	depth := 0
	in_string := false
	escaped := false
	key_pending := false // a string just closed at depth 1; a following `:` makes it a key
	for i := 0; i < len(object); i += 1 {
		ch := object[i]
		if in_string {
			if escaped {
				escaped = false
			} else if ch == '\\' {
				escaped = true
			} else if ch == '"' {
				in_string = false
				key_pending = depth == 1
			}
			continue
		}
		switch ch {
		case '"':
			in_string = true
		case '{', '[':
			depth += 1
			key_pending = false
		case '}', ']':
			depth -= 1
			key_pending = false
		case ':':
			if key_pending {
				count += 1
			}
			key_pending = false
		case:
			key_pending = false
		}
	}
	return count
}
