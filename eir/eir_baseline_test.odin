// Baseline-ratchet tests: the gate's floor is (1) build_baseline sums total_dedup_value
// over every class and content-addresses each by its fnv64a id, (2) the baseline JSON is
// byte-stable across renders and round-trips through parse_baseline, (3) the gate passes
// at the baseline and on any improvement (debt at or below the ceiling), (4) it regresses
// — and names the culprit — when a NEW class appears or an existing class GROWS instances
// so the total rises, (5) a scan whose options differ from the baseline is refused, and
// (6) parse_baseline rejects a wrong-schema or malformed file. Classes are constructed
// directly so the gate is pinned independent of the clone engine's hashing.
package eir

import "core:strings"
import "core:testing"

// bsite builds one Clone_Instance at a location (non-test).
@(private = "file")
bsite :: proc(path: string, line_start, line_end: int) -> Clone_Instance {
	return Clone_Instance{path = path, is_test = false, line_start = line_start, line_end = line_end}
}

// bcls builds one Clone_Class, copying the variadic sites into a stable temp slice. The
// hash is the content id the baseline keys on; distinct hashes model distinct classes.
@(private = "file")
bcls :: proc(hash: u64, node_count: int, kind: string, sites: ..Clone_Instance) -> Clone_Class {
	owned := make([]Clone_Instance, len(sites), context.temp_allocator)
	copy(owned, sites)
	return Clone_Class{hash = hash, node_count = node_count, kind = kind, instances = owned}
}

// debt_classes is a two-class set: A (10 nodes x 3 sites = dedup 20) and B (25 nodes x 2
// sites = dedup 25), total dedup_value 45.
@(private = "file")
debt_classes :: proc() -> []Clone_Class {
	a := bcls(0xA1, 10, "block", bsite("a.odin", 10, 20), bsite("b.odin", 30, 40), bsite("c.odin", 50, 60))
	b := bcls(0xB2, 25, "proc_lit", bsite("d.odin", 1, 9), bsite("e.odin", 11, 19))
	out := make([]Clone_Class, 2, context.temp_allocator)
	out[0] = a
	out[1] = b
	return out
}

// gate_opts is the option set the gate tests baseline and compare under.
@(private = "file")
gate_opts :: proc() -> Dup_Options {
	return Dup_Options{min_nodes = DEFAULT_MIN_NODES, fold_literals = false}
}

// test_baseline_build_and_total pins build_baseline: total_dedup_value sums every class
// (20 + 25 = 45), and each class is recorded with a content id and its leverage metric.
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

// test_baseline_json_byte_stable_and_roundtrip pins the file contract: two renders of the
// same debt are byte-identical, and the rendered file parses back into an equal baseline.
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

// test_gate_passes_at_baseline pins the no-op case: comparing a baseline against the
// identical debt is not a regression and surfaces no new or grown classes.
@(test)
test_gate_passes_at_baseline :: proc(t: ^testing.T) {
	baseline := build_baseline(debt_classes(), gate_opts(), nil, context.temp_allocator)
	verdict := compare_baseline(baseline, debt_classes(), gate_opts(), nil, context.temp_allocator)
	testing.expect(t, !verdict.regressed, "identical debt must not regress")
	testing.expect_value(t, verdict.current_total, 45)
	testing.expect_value(t, len(verdict.new_classes), 0)
	testing.expect_value(t, len(verdict.grown_classes), 0)
}

// test_gate_fails_on_new_class pins the regression: a third class raises the total above
// the baseline, and the gate names it as a new content id.
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
		// The verdict carries the CURRENT-scan class with its full site list, so the gate
		// failure can emit a diagnostic per site — not just name the class.
		testing.expect_value(t, verdict.new_classes[0].hash, u64(0xC3))
		testing.expect_value(t, len(verdict.new_classes[0].instances), 2)
	}
}

// test_gate_fails_on_grown_class pins the instance-growth regression: the SAME content id
// gaining a site raises its dedup_value and the total, and the gate names it as grown,
// not new.
@(test)
test_gate_fails_on_grown_class :: proc(t: ^testing.T) {
	baseline := build_baseline(debt_classes(), gate_opts(), nil, context.temp_allocator)

	// Class B (hash 0xB2) gains a third site: dedup 25 -> 50, total 45 -> 70.
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

// test_gate_passes_on_improvement pins the monotone direction: dropping a class lowers the
// total below the baseline, which is allowed (the gate fails only ABOVE the ceiling).
@(test)
test_gate_passes_on_improvement :: proc(t: ^testing.T) {
	baseline := build_baseline(debt_classes(), gate_opts(), nil, context.temp_allocator)

	only_a := make([]Clone_Class, 1, context.temp_allocator)
	only_a[0] = bcls(0xA1, 10, "block", bsite("a.odin", 10, 20), bsite("b.odin", 30, 40), bsite("c.odin", 50, 60))

	verdict := compare_baseline(baseline, only_a, gate_opts(), nil, context.temp_allocator)
	testing.expect(t, !verdict.regressed, "removing duplication must pass the gate")
	testing.expect(t, verdict.current_total < verdict.baseline_total, "the total must fall")
}

// test_scan_mismatch_detected pins the apples-to-oranges guard: a different min_nodes,
// fold_literals, or exclude set makes the class sets incomparable, and the gate refuses.
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

// test_parse_rejects_bad_input pins parse_baseline's guard: malformed JSON and a
// wrong-schema object both fail, so the gate surfaces a usage error rather than passing on
// a baseline it cannot trust.
@(test)
test_parse_rejects_bad_input :: proc(t: ^testing.T) {
	_, bad_json := parse_baseline("{not json", context.temp_allocator)
	testing.expect(t, !bad_json, "malformed JSON must not parse")

	wrong := strings.concatenate({`{"schema_version":999,"classes":[]}`}, context.temp_allocator)
	_, bad_schema := parse_baseline(wrong, context.temp_allocator)
	testing.expect(t, !bad_schema, "an unknown schema version must be rejected")
}
