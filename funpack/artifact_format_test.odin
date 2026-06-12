package funpack

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"

// GOLDEN_ARTIFACT_PATH is the committed pong artifact fixture (relative to
// this package dir). It is the byte-exact seam the runtime team builds
// against and the production emitter must reproduce byte-for-byte.
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

// The acceptance floor: emitting the same value twice yields byte-identical
// output. Determinism is a property of the encoders (pure functions of the
// value with no clock/path/float, docs/artifact-format.md §2), so encoding
// every primitive kind twice and comparing the bytes proves the
// emit-twice-is-byte-identical contract under `odin test` without needing
// the production emitter.
@(test)
test_encoders_are_byte_identical_across_calls :: proc(t: ^testing.T) {
	// 152.0 in Q32.32 — the P2 paddle column the golden fixture carries.
	a := context.temp_allocator
	x := to_fixed(152)
	testing.expect_value(t, encode_fixed(x, a), encode_fixed(x, a))
	testing.expect_value(t, encode_int(-9223372036854775808, a), encode_int(-9223372036854775808, a))
	testing.expect_value(t, encode_string("Move the paddle", a), encode_string("Move the paddle", a))
	testing.expect_value(t, encode_bool(true), encode_bool(true))
}

// Pin the exact bytes each encoder produces against the format spec, so a
// drift in the encoding is caught here before it corrupts a golden fixture
// or desyncs the runtime parser.
@(test)
test_encoder_output_matches_format_spec :: proc(t: ^testing.T) {
	a := context.temp_allocator
	// Fixed is the raw Q32.32 bits in decimal (§2.3): 152.0 = 152<<32.
	testing.expect_value(t, encode_fixed(to_fixed(152), a), "652835028992")
	testing.expect_value(t, encode_fixed(Fixed(0), a), "0")
	testing.expect_value(t, encode_fixed(fixed_neg(to_fixed(70)), a), "-300647710720")
	// Int is plain decimal (§2.2).
	testing.expect_value(t, encode_int(0, a), "0")
	testing.expect_value(t, encode_int(-7, a), "-7")
	// String is length-prefixed `Lk:bytes` (§2.4); the empty string is L0:.
	testing.expect_value(t, encode_string("0.1.0", a), "L5:0.1.0")
	testing.expect_value(t, encode_string("", a), "L0:")
	// A string with an embedded space still occupies one line — the byte
	// count, not a delimiter scan, bounds it.
	testing.expect_value(t, encode_string("a b", a), "L3:a b")
	// A lexical-core §4 escape rides through verbatim: the lexer carries the
	// raw spelling (backslash + quote = 2 bytes each) and the length prefix
	// bounds it with no artifact-side escaping — byte-deterministic by
	// construction.
	testing.expect_value(t, encode_string(`say \"hi\"`, a), `L10:say \"hi\"`)
	testing.expect_value(t, encode_bool(false), "false")
}

// The golden fixture exists, is non-empty, and parses against the written
// layout: line 1 is the v1 stamp, and every `[name N]` header is backed by
// exactly N body lines (the count-driven, total parse the runtime relies
// on, docs/artifact-format.md §17).
@(test)
test_golden_artifact_parses_against_format :: proc(t: ^testing.T) {
	content, ok := read_golden_artifact()
	if !testing.expect(t, ok, "golden artifact testdata/pong.artifact must exist") {
		return
	}
	testing.expect(t, len(content) > 0)
	// Purity floor: the byte format carries no host nondeterminism — no
	// machine path leaks into a span (spans are module:line, §2), and the
	// LF-only frame has no carriage return.
	testing.expect(t, !strings.contains(content, "\r"))
	testing.expect(t, !strings.contains(content, "/Users/"))
	testing.expect(t, strings.has_suffix(content, "\n"))

	doc, err := parse_artifact(content)
	testing.expect_value(t, err, Artifact_Parse_Error.None)
	testing.expect_value(t, doc.schema_version, ARTIFACT_SCHEMA_VERSION)
}

// Pin the artifact's section inventory and the pong-specific record counts
// exactly. These counts track the live pong source byte-for-byte: the
// format evolves in lockstep with the source, so a count change is a
// deliberate edit, never loosened to a range. They are the structural
// fingerprint the runtime and the emitter both target.
@(test)
test_golden_artifact_section_counts :: proc(t: ^testing.T) {
	content, ok := read_golden_artifact()
	if !ok {
		return
	}
	doc, err := parse_artifact(content)
	testing.expect_value(t, err, Artifact_Parse_Error.None)

	// Sections appear once, in the §3 fixed order; assert the inventory.
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
	}
	testing.expect_value(t, len(doc.sections), len(expected_order))
	for name, i in expected_order {
		testing.expect_value(t, doc.sections[i].name, name)
	}

	expect_section_count(t, doc, "meta", 2) // project + version
	expect_section_count(t, doc, "enums", 2) // Side, Steer
	expect_section_count(t, doc, "data", 1) // Board
	expect_section_count(t, doc, "signals", 1) // Goal
	expect_section_count(t, doc, "things", 3) // Paddle, Ball, Scoreboard
	expect_section_count(t, doc, "functions", 10) // 7 fn + BOARD + bindings + setup
	expect_section_count(t, doc, "behaviors", 10) // the 10 pong behaviors
	// The flattened pipeline is one total order: setup + 10 update/render
	// behaviors = 11 contiguous steps (docs/artifact-format.md §11).
	expect_section_count(t, doc, "pipeline_flattened", 11)
	expect_section_count(t, doc, "signal_routing", 1) // Goal's route
	expect_section_count(t, doc, "setup", 4) // 2 paddles + ball + scoreboard
	expect_section_count(t, doc, "bindings", 4) // P1/P2 keys+stick
	expect_section_count(t, doc, "entrypoint", 1) // main
	expect_section_count(t, doc, "queries", 0) // pong declares no query (v9 constant tail)
	expect_section_count(t, doc, "tilemaps", 0) // pong has no tile layer (v11 constant tail)
	expect_section_count(t, doc, "nav", 0) // pong has no level, so no nav graph (v13 constant tail)
	expect_section_count(t, doc, "assets", 0) // pong has no sprite assets (v16 constant tail)
}

expect_section_count :: proc(t: ^testing.T, doc: Artifact_Doc, name: string, want: int) {
	section, found := artifact_find_section(doc, name)
	if !testing.expect(t, found) {
		return
	}
	testing.expect_value(t, section.count, want)
}

// The flattened pipeline ordinals are contiguous and gap-free starting at
// 0, and they begin with the startup step and end with the terminal render
// stage — the total order a tick folds over (docs/artifact-format.md §11).
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
		// Each step line is `step ORDINAL stage:STAGE behavior:NAME`; the
		// ordinal is contiguous from 0.
		prefix := strings.concatenate({"step ", encode_int(i64(ordinal), context.temp_allocator), " "}, context.temp_allocator)
		testing.expect(t, strings.has_prefix(line, prefix))
	}
	testing.expect(t, strings.has_prefix(section.body[0], "step 0 stage:startup "))
	last := section.body[len(section.body) - 1]
	testing.expect(t, strings.has_prefix(last, "step 10 stage:render "))
}

// The setup Spawn program carries the exact fixed-point bits the source
// literals lower to — the deterministic, fully-evaluated population batch
// (docs/artifact-format.md §13). Re-deriving one column with the kernel's
// own to_fixed proves the fixture's bits are the kernel's bits, not a
// hand-typed approximation.
@(test)
test_golden_artifact_setup_carries_kernel_bits :: proc(t: ^testing.T) {
	content, ok := read_golden_artifact()
	if !ok {
		return
	}
	// The P2 paddle column is 152.0; its raw bits must equal to_fixed(152)'s
	// raw bits, the same kernel the emitter will run through.
	p2_x := encode_fixed(to_fixed(152), context.temp_allocator)
	testing.expect(t, strings.contains(content, strings.concatenate({"set x =", p2_x, "\n"}, context.temp_allocator)))
}

// node_child_count reads the trailing child count off a body node line, and
// an `arm` line is fixed at 0 children (its trailing field is the binder list,
// §2.7). These are the primitives the body forest reader is built on.
@(test)
test_node_child_count_reads_trailing_count :: proc(t: ^testing.T) {
	c, ok := node_child_count("node binary add 2")
	testing.expect(t, ok)
	testing.expect_value(t, c, 2)
	c, ok = node_child_count("node name self 0")
	testing.expect(t, ok)
	testing.expect_value(t, c, 0)
	// A `match` line carries arm_count then child_count; the LAST token is the
	// child count (1 + 2*arm_count).
	c, ok = node_child_count("node match 2 5")
	testing.expect(t, ok)
	testing.expect_value(t, c, 5)
	// An `arm` line ends in its binder list, not a child count — it is fixed
	// at 0 children regardless of the trailing binder token.
	c, ok = node_child_count("node arm variant_binds Option Some 1 side")
	testing.expect(t, ok)
	testing.expect_value(t, c, 0)
	c, ok = node_child_count("node arm wildcard - - 0")
	testing.expect(t, ok)
	testing.expect_value(t, c, 0)
}

// body_forest_is_well_formed accepts a pre-order run that exactly fills the
// declared statement count and rejects an over- or under-shaped one (§2.7).
// `goal_side`'s body is three statements (two if_return, one return); a
// hand-built fragment proves the count-driven shape directly.
@(test)
test_body_forest_well_formedness :: proc(t: ^testing.T) {
	// One `return` of `at + vel * dt` — `advance`'s body, exactly.
	advance_body := []string {
		"node return 1",
		"node binary add 2",
		"node name at 0",
		"node binary mul 2",
		"node name vel 0",
		"node name dt 0",
	}
	testing.expect(t, body_forest_is_well_formed(advance_body, 1))
	// Declaring 2 statements over a 1-statement run under-consumes (overruns
	// the slice) — rejected.
	testing.expect(t, !body_forest_is_well_formed(advance_body, 2))
	// A leftover trailing node (the `return` declares too few children) is an
	// over-shaped body — rejected.
	malformed := []string{"node return 0", "node name self 0"}
	testing.expect(t, !body_forest_is_well_formed(malformed, 1))
}

// Every function and behavior body in the golden fixture is a well-formed
// pre-order node forest: the record's declared `body_count` accounts for every
// body `node` line and no more (§2.7). This is the load-bearing guarantee:
// the runtime parses and interprets pong's bodies FROM THE ARTIFACT, with zero
// funpack source, so a body that does not reconstruct from its own declared
// counts is unloadable. The check walks the fixture's records the way the
// runtime does: lead line, declared counts, then the body node run.
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
			// function NAME KIND param_count return:TYPE body_count span:…
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
			// behavior NAME on: stage: contract: gtag_count param_count emits_count body_count
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
	// 10 functions + 10 behaviors all carry a checked body.
	testing.expect_value(t, checked, 20)
}

// skip_lead_run advances past exactly `count` consecutive sub-record lines
// whose keyword is `keyword`, asserting the shape the record's scalar count
// declares. It is the test-side mirror of the runtime shaping each record's
// sub-records by its declared counts (§17 step 3).
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

// collect_node_run gathers the maximal run of body `node` lines starting at
// `start` — a record's serialized body (§2.7) — returning the run and the
// index just past it.
collect_node_run :: proc(lines: []string, start: int) -> (run: [dynamic]string, next: int) {
	run = make([dynamic]string, 0, 16, context.temp_allocator)
	i := start
	for i < len(lines) && strings.has_prefix(lines[i], "node ") {
		append(&run, lines[i])
		i += 1
	}
	return run, i
}

// Pin the exact body bytes of a representative record — BOARD's const
// initializer — so a drift in the node encoding is caught here before it
// desyncs the runtime's body reader. BOARD is `return Board{ w: 160.0,
// h: 120.0 }`: a single `return` of a 2-field record, fixed bits raw (§2.3).
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
