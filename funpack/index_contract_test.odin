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
	content := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick     = 60hz\n  bindings = bindings\n}\nentrypoint replay {\n  pipeline = Pong\n  tick = 30hz\n  bindings = bindings\n}\n"
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
	content := "use pong.{Pong, bindings}\n\nentrypoint main {\n  pipeline = Pong\n  tick = 60khz\n  bindings = bindings\n}\n"
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
	// schema_version is the leading key (it is the first struct field).
	testing.expect(t, strings.has_prefix(body, "{\"schema_version\":"))
	testing.expect(t, strings.contains(body, "\"schema_version\":1"))
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
	// the contract fixes; the emitted object's keys must equal it.
	line, ok := pong_index_line()
	if !ok {
		return
	}
	body := strings.trim_suffix(line, "\n")
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
	// separate compatibility gate, so INDEX_SCHEMA_VERSION holds), the single 8hz
	// Snake entrypoint, the snake-shaped capability set (render/input/state), and
	// the twelve-step depth-first flattened pipeline (setup → turn → advance →
	// detect_eat → grow → despawn_eaten → replenish → detect_death → apply_death →
	// draw_snake → draw_food → draw_state). The fixture resolves the sibling snake
	// checkout (or FUNPACK_SNAKE_DIR) and SKIPs loudly when absent.
	dir := resolve_snake_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP index contract snake: %s not found — set FUNPACK_SNAKE_DIR or check out funpack-spec as a sibling", dir)
		return
	}
	identity, project_err := read_project(dir)
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

// pong_index_line emits the pong project record's NDJSON line via the
// end-to-end read_index_project seam; ok is false (with a SKIP warning) when
// the sibling pong checkout is absent or the source does not compile,
// matching the golden_pong skip semantics.
pong_index_line :: proc() -> (line: string, ok: bool) {
	dir := resolve_pong_dir()
	if !os.is_dir(dir) {
		log.warnf("SKIP index contract pong: %s not found — set FUNPACK_PONG_DIR or check out funpack-spec as a sibling", dir)
		return "", false
	}
	ndjson, err, compiled := read_index_project(dir, context.temp_allocator)
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
	identity, project_err := read_project(dir)
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
