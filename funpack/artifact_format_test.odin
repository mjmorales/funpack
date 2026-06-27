package funpack

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

GOLDEN_ARTIFACT_PATH :: "testdata/pong.artifact"

golden_artifact_path :: proc() -> string {
	resolved, _ := filepath.join({#directory, GOLDEN_ARTIFACT_PATH}, context.temp_allocator)
	return resolved
}

read_golden_artifact :: proc() -> (content: string, ok: bool) {
	bytes, err := os.read_entire_file_from_path(golden_artifact_path(), context.temp_allocator)
	if err != nil {
		return "", false
	}
	return string(bytes), true
}

@(test)
test_encoders_are_byte_identical_across_calls :: proc(t: ^testing.T) {
	a := context.temp_allocator
	x := to_fixed(152)
	testing.expect_value(t, encode_fixed(x, a), encode_fixed(x, a))
	testing.expect_value(t, encode_int(-9223372036854775808, a), encode_int(-9223372036854775808, a))
	testing.expect_value(t, encode_string("Move the paddle", a), encode_string("Move the paddle", a))
	testing.expect_value(t, encode_bool(true), encode_bool(true))
}

@(test)
test_encoder_output_matches_format_spec :: proc(t: ^testing.T) {
	a := context.temp_allocator
	testing.expect_value(t, encode_fixed(to_fixed(152), a), "652835028992")
	testing.expect_value(t, encode_fixed(Fixed(0), a), "0")
	testing.expect_value(t, encode_fixed(fixed_neg(to_fixed(70)), a), "-300647710720")
	testing.expect_value(t, encode_int(0, a), "0")
	testing.expect_value(t, encode_int(-7, a), "-7")
	testing.expect_value(t, encode_string("0.1.0", a), "L5:0.1.0")
	testing.expect_value(t, encode_string("", a), "L0:")
	testing.expect_value(t, encode_string("a b", a), "L3:a b")
	testing.expect_value(t, encode_string(`say \"hi\"`, a), `L10:say \"hi\"`)
	testing.expect_value(t, encode_bool(false), "false")
}

@(test)
test_golden_artifact_parses_against_format :: proc(t: ^testing.T) {
	content, ok := read_golden_artifact()
	if !testing.expect(t, ok, "golden artifact testdata/pong.artifact must exist") {
		return
	}
	testing.expect(t, len(content) > 0)
	testing.expect(t, !strings.contains(content, "\r"))
	testing.expect(t, !strings.contains(content, "/Users/"))
	testing.expect(t, strings.has_suffix(content, "\n"))

	doc, err := parse_artifact(content)
	testing.expect_value(t, err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)
}

@(test)
test_golden_artifact_section_counts :: proc(t: ^testing.T) {
	content, ok := read_golden_artifact()
	if !ok {
		return
	}
	doc, err := parse_artifact(content)
	testing.expect_value(t, err, Artifact_Parse_Error.None)

	expected_order := []string{
		"meta",
		"enums",
		"data",
		"signals",
		"things",
		"functions",
		"behaviors",
		"pipeline_flattened",
		"signal_routing",
		"setup",
		"bindings",
		"entrypoint",
		"queries",
		"tilemaps",
		"nav",
		"assets",
		"probes",
	}
	testing.expect_value(t, len(doc.sections), len(expected_order))
	for name, i in expected_order {
		testing.expect_value(t, doc.sections[i].name, name)
	}

	expect_section_count(t, doc, "meta", 2)
	expect_section_count(t, doc, "enums", 2)
	expect_section_count(t, doc, "data", 1)
	expect_section_count(t, doc, "signals", 1)
	expect_section_count(t, doc, "things", 3)
	expect_section_count(t, doc, "functions", 10)
	expect_section_count(t, doc, "behaviors", 10)
	expect_section_count(t, doc, "pipeline_flattened", 11)
	expect_section_count(t, doc, "signal_routing", 1)
	expect_section_count(t, doc, "setup", 4)
	expect_section_count(t, doc, "bindings", 4)
	expect_section_count(t, doc, "entrypoint", 1)
	expect_section_count(t, doc, "queries", 0)
	expect_section_count(t, doc, "tilemaps", 0)
	expect_section_count(t, doc, "nav", 0)
	expect_section_count(t, doc, "assets", 0)
	expect_section_count(t, doc, "probes", 0)
}

expect_section_count :: proc(t: ^testing.T, doc: Artifact_Doc, name: string, want: int) {
	section, found := artifact_find_section(doc, name)
	if !testing.expect(t, found) {
		return
	}
	testing.expect_value(t, section.count, want)
}

@(test)
test_golden_artifact_pipeline_order_is_total :: proc(t: ^testing.T) {
	content, ok := read_golden_artifact()
	if !ok {
		return
	}
	doc, err := parse_artifact(content)
	testing.expect_value(t, err, Artifact_Parse_Error.None)

	section, found := artifact_find_section(doc, "pipeline_flattened")
	if !testing.expect(t, found) {
		return
	}
	for line, ordinal in section.body {
		prefix := strings.concatenate({"step ", encode_int(i64(ordinal), context.temp_allocator), " "}, context.temp_allocator)
		testing.expect(t, strings.has_prefix(line, prefix))
	}
	testing.expect(t, strings.has_prefix(section.body[0], "step 0 stage:startup "))
	last := section.body[len(section.body) - 1]
	testing.expect(t, strings.has_prefix(last, "step 10 stage:render "))
}

@(test)
test_golden_artifact_setup_carries_kernel_bits :: proc(t: ^testing.T) {
	content, ok := read_golden_artifact()
	if !ok {
		return
	}
	p2_x := encode_fixed(to_fixed(152), context.temp_allocator)
	testing.expect(t, strings.contains(content, strings.concatenate({"set x =", p2_x, "\n"}, context.temp_allocator)))
}

@(test)
test_node_child_count_reads_trailing_count :: proc(t: ^testing.T) {
	c, ok := node_child_count("node binary add 2")
	testing.expect(t, ok)
	testing.expect_value(t, c, 2)
	c, ok = node_child_count("node name self 0")
	testing.expect(t, ok)
	testing.expect_value(t, c, 0)
	c, ok = node_child_count("node match 2 5")
	testing.expect(t, ok)
	testing.expect_value(t, c, 5)
	c, ok = node_child_count("node arm variant_binds Option Some 1 side")
	testing.expect(t, ok)
	testing.expect_value(t, c, 0)
	c, ok = node_child_count("node arm wildcard - - 0")
	testing.expect(t, ok)
	testing.expect_value(t, c, 0)
}

@(test)
test_body_forest_well_formedness :: proc(t: ^testing.T) {
	advance_body := []string {
		"node return 1",
		"node binary add 2",
		"node name at 0",
		"node binary mul 2",
		"node name vel 0",
		"node name dt 0",
	}
	testing.expect(t, body_forest_is_well_formed(advance_body, 1))
	testing.expect(t, !body_forest_is_well_formed(advance_body, 2))
	malformed := []string{"node return 0", "node name self 0"}
	testing.expect(t, !body_forest_is_well_formed(malformed, 1))
}

@(test)
test_golden_artifact_bodies_are_well_formed :: proc(t: ^testing.T) {
	content, ok := read_golden_artifact()
	if !ok {
		return
	}
	lines := split_artifact_lines(content)
	checked := 0
	i := 0
	for i < len(lines) {
		line := lines[i]
		switch {
		case strings.has_prefix(line, "function "):
			fields := strings.fields(line, context.temp_allocator)
			param_count, _ := strconv.parse_int(fields[3])
			body_count, _ := strconv.parse_int(fields[5])
			i += 1
			i = skip_lead_run(lines, i, "param", param_count)
			body: [dynamic]string
			body, i = collect_node_run(lines, i)
			testing.expectf(
				t,
				body_forest_is_well_formed(body[:], body_count),
				"function %s body is not well-formed against body_count %d",
				fields[1],
				body_count,
			)
			checked += 1
		case strings.has_prefix(line, "behavior "):
			fields := strings.fields(line, context.temp_allocator)
			gtag_count, _ := strconv.parse_int(fields[5])
			param_count, _ := strconv.parse_int(fields[6])
			emits_count, _ := strconv.parse_int(fields[7])
			body_count, _ := strconv.parse_int(fields[8])
			i += 1
			i = skip_lead_run(lines, i, "gtag", gtag_count)
			i = skip_lead_run(lines, i, "param", param_count)
			i = skip_lead_run(lines, i, "emit", emits_count)
			body: [dynamic]string
			body, i = collect_node_run(lines, i)
			testing.expectf(
				t,
				body_forest_is_well_formed(body[:], body_count),
				"behavior %s body is not well-formed against body_count %d",
				fields[1],
				body_count,
			)
			checked += 1
		case:
			i += 1
		}
	}
	testing.expect_value(t, checked, 20)
}

skip_lead_run :: proc(lines: []string, start: int, keyword: string, count: int) -> int {
	prefix := strings.concatenate({keyword, " "}, context.temp_allocator)
	i := start
	for _ in 0 ..< count {
		if i < len(lines) && strings.has_prefix(lines[i], prefix) {
			i += 1
		}
	}
	return i
}

collect_node_run :: proc(lines: []string, start: int) -> (run: [dynamic]string, next: int) {
	run = make([dynamic]string, 0, 16, context.temp_allocator)
	i := start
	for i < len(lines) && strings.has_prefix(lines[i], "node ") {
		append(&run, lines[i])
		i += 1
	}
	return run, i
}

@(test)
test_const_body_encoding_is_pinned :: proc(t: ^testing.T) {
	content, ok := read_golden_artifact()
	if !ok {
		return
	}
	w_bits := encode_fixed(to_fixed(160), context.temp_allocator)
	h_bits := encode_fixed(to_fixed(120), context.temp_allocator)
	expected := strings.concatenate(
		{
			"function BOARD const 0 return:Board 1 span:pong:19\n",
			"node return 1\n",
			"node record Board 2 2\n",
			"node recfield w 1\n",
			"node fixed ",
			w_bits,
			" 0\n",
			"node recfield h 1\n",
			"node fixed ",
			h_bits,
			" 0\n",
		},
		context.temp_allocator,
	)
	testing.expect(t, strings.contains(content, expected))
}
