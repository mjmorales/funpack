package funpack

import "core:os"
import "core:path/filepath"
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
	testing.expect_value(t, encode_bool(false), "false")
}

// The golden fixture exists, is non-empty, and parses against the written
// layout: line 1 is the v1 stamp, and every `[name N]` header is backed by
// exactly N body lines (the count-driven, total parse the runtime relies
// on, docs/artifact-format.md §16).
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
