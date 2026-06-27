package eir

import "core:strings"
import "core:testing"

@(private = "file")
bsite :: proc(path: string, line_start, line_end: int) -> Clone_Instance {
	return Clone_Instance{path = path, is_test = false, line_start = line_start, line_end = line_end}
}

@(private = "file")
bcls :: proc(hash: u64, node_count: int, kind: string, sites: ..Clone_Instance) -> Clone_Class {
	owned := make([]Clone_Instance, len(sites), context.temp_allocator)
	copy(owned, sites)
	return Clone_Class{hash = hash, node_count = node_count, kind = kind, instances = owned}
}

@(private = "file")
debt_classes :: proc() -> []Clone_Class {
	a := bcls(0xA1, 10, "block", bsite("a.odin", 10, 20), bsite("b.odin", 30, 40), bsite("c.odin", 50, 60))
	b := bcls(0xB2, 25, "proc_lit", bsite("d.odin", 1, 9), bsite("e.odin", 11, 19))
	out := make([]Clone_Class, 2, context.temp_allocator)
	out[0] = a
	out[1] = b
	return out
}

@(private = "file")
gate_opts :: proc() -> Dup_Options {
	return Dup_Options{min_nodes = DEFAULT_MIN_NODES, fold_literals = false}
}

@(test)
test_baseline_build_and_total :: proc(t: ^testing.T) {
	baseline := build_baseline(debt_classes(), gate_opts(), nil, context.temp_allocator)
	testing.expect_value(t, baseline.schema_version, DUP_BASELINE_SCHEMA_VERSION)
	testing.expect_value(t, baseline.total_dedup_value, 45)
	testing.expect_value(t, len(baseline.classes), 2)
	for bc in baseline.classes {
		testing.expect(t, len(bc.id) == 16, "a content id is a zero-padded 16-hex digest")
		testing.expect(t, bc.dedup_value == bc.node_count * (bc.instances - 1), "recorded dedup_value matches the class")
	}
}

@(test)
test_baseline_json_byte_stable_and_roundtrip :: proc(t: ^testing.T) {
	baseline := build_baseline(debt_classes(), gate_opts(), {"*.gen.odin"}, context.temp_allocator)
	first := render_baseline_json(baseline, context.temp_allocator)
	second := render_baseline_json(baseline, context.temp_allocator)
	testing.expect(t, first == second, "the baseline JSON must be byte-stable across renders")

	parsed, ok := parse_baseline(first, context.temp_allocator)
	testing.expect(t, ok, "the rendered baseline must parse back")
	testing.expect_value(t, parsed.total_dedup_value, 45)
	testing.expect_value(t, len(parsed.classes), 2)
	testing.expect_value(t, len(parsed.excludes), 1)
}

@(test)
test_gate_passes_at_baseline :: proc(t: ^testing.T) {
	baseline := build_baseline(debt_classes(), gate_opts(), nil, context.temp_allocator)
	verdict := compare_baseline(baseline, debt_classes(), gate_opts(), nil, context.temp_allocator)
	testing.expect(t, !verdict.regressed, "identical debt must not regress")
	testing.expect_value(t, verdict.current_total, 45)
	testing.expect_value(t, len(verdict.new_classes), 0)
	testing.expect_value(t, len(verdict.grown_classes), 0)
}

@(test)
test_gate_fails_on_new_class :: proc(t: ^testing.T) {
	baseline := build_baseline(debt_classes(), gate_opts(), nil, context.temp_allocator)

	grown := make([dynamic]Clone_Class, 0, 3, context.temp_allocator)
	append(&grown, ..debt_classes())
	append(&grown, bcls(0xC3, 30, "for", bsite("g.odin", 5, 40), bsite("h.odin", 45, 80)))

	verdict := compare_baseline(baseline, grown[:], gate_opts(), nil, context.temp_allocator)
	testing.expect(t, verdict.regressed, "a new clone class must regress the gate")
	testing.expect(t, verdict.current_total > verdict.baseline_total, "the total must rise")
	testing.expect_value(t, len(verdict.new_classes), 1)
	if len(verdict.new_classes) == 1 {
		testing.expect_value(t, verdict.new_classes[0].hash, u64(0xC3))
		testing.expect_value(t, len(verdict.new_classes[0].instances), 2)
	}
}

@(test)
test_gate_fails_on_grown_class :: proc(t: ^testing.T) {
	baseline := build_baseline(debt_classes(), gate_opts(), nil, context.temp_allocator)

	a := bcls(0xA1, 10, "block", bsite("a.odin", 10, 20), bsite("b.odin", 30, 40), bsite("c.odin", 50, 60))
	b := bcls(0xB2, 25, "proc_lit", bsite("d.odin", 1, 9), bsite("e.odin", 11, 19), bsite("z.odin", 21, 29))
	current := make([]Clone_Class, 2, context.temp_allocator)
	current[0] = a
	current[1] = b

	verdict := compare_baseline(baseline, current, gate_opts(), nil, context.temp_allocator)
	testing.expect(t, verdict.regressed, "a grown clone class must regress the gate")
	testing.expect_value(t, verdict.current_total, 70)
	testing.expect_value(t, len(verdict.new_classes), 0)
	testing.expect_value(t, len(verdict.grown_classes), 1)
}

@(test)
test_gate_passes_on_improvement :: proc(t: ^testing.T) {
	baseline := build_baseline(debt_classes(), gate_opts(), nil, context.temp_allocator)

	only_a := make([]Clone_Class, 1, context.temp_allocator)
	only_a[0] = bcls(0xA1, 10, "block", bsite("a.odin", 10, 20), bsite("b.odin", 30, 40), bsite("c.odin", 50, 60))

	verdict := compare_baseline(baseline, only_a, gate_opts(), nil, context.temp_allocator)
	testing.expect(t, !verdict.regressed, "removing duplication must pass the gate")
	testing.expect(t, verdict.current_total < verdict.baseline_total, "the total must fall")
}

@(test)
test_scan_mismatch_detected :: proc(t: ^testing.T) {
	baseline := build_baseline(debt_classes(), gate_opts(), {"*.gen.odin"}, context.temp_allocator)

	testing.expect(t, baseline_scan_matches(baseline, gate_opts(), {"*.gen.odin"}), "same scan must match")
	testing.expect(
		t,
		!baseline_scan_matches(baseline, Dup_Options{min_nodes = 50, fold_literals = false}, {"*.gen.odin"}),
		"a different min_nodes must not match",
	)
	testing.expect(
		t,
		!baseline_scan_matches(baseline, Dup_Options{min_nodes = DEFAULT_MIN_NODES, fold_literals = true}, {"*.gen.odin"}),
		"a different fold_literals must not match",
	)
	testing.expect(t, !baseline_scan_matches(baseline, gate_opts(), nil), "a different exclude set must not match")
}

@(test)
test_parse_rejects_bad_input :: proc(t: ^testing.T) {
	_, bad_json := parse_baseline("{not json", context.temp_allocator)
	testing.expect(t, !bad_json, "malformed JSON must not parse")

	wrong := strings.concatenate({`{"schema_version":999,"classes":[]}`}, context.temp_allocator)
	_, bad_schema := parse_baseline(wrong, context.temp_allocator)
	testing.expect(t, !bad_schema, "an unknown schema version must be rejected")
}
