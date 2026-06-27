package funpack

import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_index_lift_entrypoint_records :: proc(t: ^testing.T) {
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
		testing.expect_value(t, tags[0], "game")
		testing.expect_value(t, tags[1], "startup")
		testing.expect_value(t, tags[2], "render")
	}
}

@(test)
test_index_contract_emits_valid_ndjson_with_schema_version :: proc(t: ^testing.T) {
	record := minimal_project_record()
	line := emit_project_record(record, context.temp_allocator)
	testing.expect(t, strings.has_suffix(line, "\n"))
	body := strings.trim_suffix(line, "\n")
	testing.expect_value(t, strings.count(body, "\n"), 0)
	testing.expect(t, strings.has_prefix(body, "{"))
	testing.expect(t, strings.has_suffix(body, "}"))
	testing.expect(t, strings.has_prefix(body, "{\"schema_version\":"))
	testing.expect(t, strings.contains(body, "\"schema_version\":6"))
}

@(test)
test_index_contract_ndjson_byte_identical_twice :: proc(t: ^testing.T) {
	record := minimal_project_record()
	first := emit_project_record(record, context.temp_allocator)
	second := emit_project_record(record, context.temp_allocator)
	testing.expect_value(t, first, second)
}

@(test)
test_index_contract_pong_project_record_exact_fields :: proc(t: ^testing.T) {
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
	testing.expect_value(t, top_level_key_count(body), len(expected_keys))
	log.infof("index contract project record NDJSON exact-match verified (%d fields)", len(expected_keys))
}

@(test)
test_index_contract_pong_authored_and_derived_values :: proc(t: ^testing.T) {
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

	testing.expect_value(t, len(record.tag_registry), 10)
	if len(record.tag_registry) == 10 {
		testing.expect_value(t, record.tag_registry[0], "game")
		testing.expect_value(t, record.tag_registry[9], "event")
	}

	testing.expect_value(t, len(record.capabilities), 3)
	testing.expect(t, index_capabilities_contains(record.capabilities, .Render))
	testing.expect(t, index_capabilities_contains(record.capabilities, .Input))
	testing.expect(t, index_capabilities_contains(record.capabilities, .State))
	testing.expect(t, !index_capabilities_contains(record.capabilities, .Netcode))
	testing.expect(t, !index_capabilities_contains(record.capabilities, .Audio))

	testing.expect_value(t, len(record.pipeline_flattened), 11)
	if len(record.pipeline_flattened) == 11 {
		testing.expect_value(t, record.pipeline_flattened[0].ordinal, 0)
		testing.expect_value(t, record.pipeline_flattened[0].stage, "startup")
		testing.expect_value(t, record.pipeline_flattened[0].behavior, "setup")
		testing.expect_value(t, record.pipeline_flattened[10].behavior, "draw_score")
	}

	testing.expect_value(t, len(record.gate_results), int(max(Gate_Family)) + 1)
	for result in record.gate_results {
		testing.expectf(t, result.passed, "gate %v unexpectedly failed on the pong golden", result.gate)
	}
}

@(test)
test_index_contract_snake_project_record :: proc(t: ^testing.T) {
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
	testing.expect_value(t, len(record.capabilities), 3)
	testing.expect(t, index_capabilities_contains(record.capabilities, .Render))
	testing.expect(t, index_capabilities_contains(record.capabilities, .Input))
	testing.expect(t, index_capabilities_contains(record.capabilities, .State))
	testing.expect_value(t, len(record.pipeline_flattened), 12)
	if len(record.pipeline_flattened) == 12 {
		testing.expect_value(t, record.pipeline_flattened[0].ordinal, 0)
		testing.expect_value(t, record.pipeline_flattened[0].behavior, "setup")
		testing.expect_value(t, record.pipeline_flattened[11].behavior, "draw_state")
	}
	testing.expect_value(t, len(record.gate_results), int(max(Gate_Family)) + 1)
	for result in record.gate_results {
		testing.expectf(t, result.passed, "gate %v unexpectedly failed on the snake golden", result.gate)
	}
	log.infof("index contract snake project record verified (12-step pipeline, schema v%d)", INDEX_SCHEMA_VERSION)
}

@(test)
test_index_contract_modding_capability_from_expose :: proc(t: ^testing.T) {
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
	first, ok := pong_index_line()
	if !ok {
		return
	}
	second, second_ok := pong_index_line()
	testing.expect(t, second_ok)
	testing.expect_value(t, first, second)
	log.infof("index contract double index emission is byte-identical NDJSON — project deterministic")
}

@(test)
test_index_contract_pong_decl_records :: proc(t: ^testing.T) {
	stream, ok := pong_index_line()
	if !ok {
		return
	}
	lines := ndjson_lines(stream)
	testing.expect_value(t, len(lines), 1 + 33)
	if len(lines) != 34 {
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
	testing.expect(t, stream_has_decl(lines, "\"qualified_name\":\"Board\"", "\"kind\":\"Data\""))
	testing.expect(t, stream_has_decl(lines, "\"qualified_name\":\"score\"", "\"emits\":[\"Goal\"]"))
	testing.expect(t, stream_has_decl(lines, "\"qualified_name\":\"tally\"", "\"mut_data\":[\"Scoreboard\"]"))
	testing.expect(t, stream_has_decl(lines, "\"qualified_name\":\"overlaps\"", "\"calls\":[\"abs\"]"))
	testing.expect(t, stream_has_decl(lines, "\"qualified_name\":\"paddle_move\"", "\"clamp\""))
	log.infof("index contract pong whole-stream decl records verified (%d decl lines)", len(lines) - 1)
}

@(test)
test_index_contract_snake_decl_records :: proc(t: ^testing.T) {
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
	testing.expect(t, stream_has_decl(lines, "\"qualified_name\":\"Cell\"", "\"kind\":\"Data\""))
	log.infof("index contract snake whole-stream decl records verified (%d decl lines)", len(lines) - 1)
}

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
	testing.expect(t, project_err != .None, "the real Project_Error cause is threaded")
	testing.expect(t, project_err != .Missing_Configs_Dir, "a present-but-malformed tree is not reported as a missing configs dir")
}

stream_has_decl :: proc(lines: []string, name_needle: string, field_needle: string) -> bool {
	for line in lines {
		if strings.contains(line, name_needle) && strings.contains(line, field_needle) {
			return true
		}
	}
	return false
}

@(test)
test_index_decl_record_ndjson_shape :: proc(t: ^testing.T) {
	record := minimal_decl_record()
	line := emit_decl_record(record, context.temp_allocator)
	testing.expect(t, strings.has_suffix(line, "\n"))
	body := strings.trim_suffix(line, "\n")
	testing.expect_value(t, strings.count(body, "\n"), 0)
	testing.expect(t, strings.has_prefix(body, "{"))
	testing.expect(t, strings.has_suffix(body, "}"))
	testing.expect(t, strings.has_prefix(body, "{\"schema_version\":"))
	testing.expect(t, strings.contains(body, "\"schema_version\":6"))
	testing.expect(t, strings.contains(body, "\"kind\":\"Behavior\""))
	log.infof("index contract decl record NDJSON shape verified (schema v%d)", INDEX_SCHEMA_VERSION)
}

@(test)
test_index_decl_record_byte_identical_twice :: proc(t: ^testing.T) {
	record := minimal_decl_record()
	first := emit_decl_record(record, context.temp_allocator)
	second := emit_decl_record(record, context.temp_allocator)
	testing.expect_value(t, first, second)
}

@(test)
test_index_decl_record_exact_key_set :: proc(t: ^testing.T) {
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
	testing.expect(t, strings.contains(body, "\"stub\":false"))
	testing.expect(t, strings.contains(body, "\"todo\":false"))
	testing.expect(t, strings.contains(body, "\"debug\":[]"))
	testing.expect(t, strings.contains(body, "\"exposed\":false"))
	testing.expect_value(t, top_level_key_count(body), len(expected_keys))
	log.infof("index contract decl record NDJSON exact-match verified (%d fields)", len(expected_keys))
}

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

ndjson_lines :: proc(stream: string) -> []string {
	trimmed := strings.trim_suffix(stream, "\n")
	if trimmed == "" {
		return nil
	}
	return strings.split(trimmed, "\n", context.temp_allocator)
}

top_level_key_count :: proc(object: string) -> int {
	count := 0
	depth := 0
	in_string := false
	escaped := false
	key_pending := false
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
