// Report-surface tests: the report turns the engine's []Clone_Class into the two
// operator-facing renderings, so its floor is (1) the leverage metrics — dedup_value
// and mass — are computed correctly, (2) classes rank by dedup_value descending in
// BOTH renderings, (3) the rank is a function of the class SET alone (shuffling the
// input yields the same order), (4) the --json render is byte-stable across calls and
// valid JSON that round-trips into Dup_Report, and (5) an empty class set renders the
// "no clones" human form and an empty JSON array. Classes are constructed directly so
// the tests pin the report independent of the clone engine's hashing.
package eir

import "core:encoding/json"
import "core:strings"
import "core:testing"

// site builds one Clone_Instance with the given location (non-test).
@(private = "file")
site :: proc(path: string, line_start, line_end: int) -> Clone_Instance {
	return Clone_Instance{path = path, is_test = false, line_start = line_start, line_end = line_end}
}

// cls builds one Clone_Class, copying the variadic sites into a stable temp slice (the
// variadic backing is transient). A class always carries >= 2 sites — the report's
// span tie-break and dedup_value both read the instance list.
@(private = "file")
cls :: proc(hash: u64, node_count: int, kind: string, sites: ..Clone_Instance) -> Clone_Class {
	owned := make([]Clone_Instance, len(sites), context.temp_allocator)
	copy(owned, sites)
	return Clone_Class{hash = hash, node_count = node_count, kind = kind, instances = owned}
}

// sample_classes is a three-class set with distinct dedup_values whose descending
// order (B 50, C 35, A 20) differs from both the hash order and any construction order
// — so a correct ranking cannot be the identity of either.
//
//   A: node_count 10 x (3 sites - 1) = dedup 20, mass 30
//   B: node_count 25 x (3 sites - 1) = dedup 50, mass 75
//   C: node_count 35 x (2 sites - 1) = dedup 35, mass 70
@(private = "file")
sample_classes :: proc() -> []Clone_Class {
	a := cls(0xA1, 10, "block", site("a.odin", 10, 20), site("b.odin", 30, 40), site("c.odin", 50, 60))
	b := cls(0xB2, 25, "proc_lit", site("d.odin", 1, 9), site("e.odin", 11, 19), site("f.odin", 21, 29))
	c := cls(0xC3, 35, "for", site("g.odin", 5, 40), site("h.odin", 45, 80))
	out := make([]Clone_Class, 3, context.temp_allocator)
	out[0] = a
	out[1] = b
	out[2] = c
	return out
}

// test_report_dedup_value_and_mass pins the two leverage metrics on a known class:
// dedup_value saves every site past the first, mass counts them all.
@(test)
test_report_dedup_value_and_mass :: proc(t: ^testing.T) {
	c := cls(0xD4, 12, "block", site("x.odin", 1, 5), site("y.odin", 7, 11), site("z.odin", 13, 17))
	testing.expect_value(t, class_dedup_value(c), 24) // 12 * (3 - 1)
	testing.expect_value(t, class_mass(c), 36) // 12 * 3
}

// test_report_ranks_by_dedup_value_desc pins the ranking key in both renderings: the
// ranked class list runs in dedup_value-descending order, and the human table's first
// data row carries the top class's first site (so the table row order matches the rank).
@(test)
test_report_ranks_by_dedup_value_desc :: proc(t: ^testing.T) {
	ranked := rank_clone_classes(sample_classes(), context.temp_allocator)

	testing.expect_value(t, len(ranked), 3)
	testing.expect_value(t, ranked[0].hash, u64(0xB2)) // dedup 50
	testing.expect_value(t, ranked[1].hash, u64(0xC3)) // dedup 35
	testing.expect_value(t, ranked[2].hash, u64(0xA1)) // dedup 20

	for i in 1 ..< len(ranked) {
		testing.expect(
			t,
			class_dedup_value(ranked[i - 1]) >= class_dedup_value(ranked[i]),
			"ranked classes must be in dedup_value-descending order",
		)
	}

	human := render_dup_human(sample_classes(), context.temp_allocator)
	lines := strings.split_lines(human, context.temp_allocator)
	// lines[0] is the header row; lines[1] is the first ranked class (B), whose first
	// site is d.odin:1-9.
	testing.expect(t, len(lines) >= 2, "the table must have a header and at least one data row")
	testing.expect(
		t,
		strings.contains(lines[1], "d.odin:1-9"),
		"the first data row must carry the top-dedup class's first site",
	)
}

// test_report_rank_independent_of_input_order pins that ranking is a function of the
// class SET: a reversed input yields a byte-identical human table and JSON, so neither
// rendering leaks the construction order.
@(test)
test_report_rank_independent_of_input_order :: proc(t: ^testing.T) {
	forward := sample_classes()
	reversed := sample_classes()
	slice_reverse(reversed)

	human_forward := render_dup_human(forward, context.temp_allocator)
	human_reversed := render_dup_human(reversed, context.temp_allocator)
	testing.expect(t, human_forward == human_reversed, "the human table must not depend on input order")

	json_forward := render_dup_json(forward, context.temp_allocator)
	json_reversed := render_dup_json(reversed, context.temp_allocator)
	testing.expect(t, json_forward == json_reversed, "the JSON must not depend on input order")
}

// slice_reverse reverses a Clone_Class slice in place — the shuffle the
// input-order-independence test applies.
@(private = "file")
slice_reverse :: proc(s: []Clone_Class) {
	for i in 0 ..< len(s) / 2 {
		j := len(s) - 1 - i
		s[i], s[j] = s[j], s[i]
	}
}

// test_report_json_byte_stable_and_valid pins the --json contract: two renders of the
// same class set are byte-identical, the output parses as valid JSON, and it round-trips
// into Dup_Report with the ranked shape (schema version, descending dedup_value, 1-based
// ranks, and the per-site locations preserved).
@(test)
test_report_json_byte_stable_and_valid :: proc(t: ^testing.T) {
	first := render_dup_json(sample_classes(), context.temp_allocator)
	second := render_dup_json(sample_classes(), context.temp_allocator)
	testing.expect(t, first == second, "the JSON render must be byte-stable across calls")

	report: Dup_Report
	err := json.unmarshal_string(first, &report, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "the JSON must parse into Dup_Report")
	testing.expect_value(t, report.schema_version, DUP_REPORT_SCHEMA_VERSION)
	testing.expect_value(t, len(report.clone_classes), 3)

	if len(report.clone_classes) == 3 {
		top := report.clone_classes[0]
		testing.expect_value(t, top.rank, 1)
		testing.expect_value(t, top.dedup_value, 50)
		testing.expect_value(t, top.mass, 75)
		testing.expect_value(t, top.instances, 3)
		testing.expect_value(t, top.kind, "proc_lit")
		testing.expect_value(t, len(top.sites), 3)
		testing.expect_value(t, top.sites[0].path, "d.odin")
		testing.expect_value(t, top.sites[0].line_start, 1)
		testing.expect_value(t, top.sites[0].line_end, 9)

		for i in 1 ..< len(report.clone_classes) {
			prev := report.clone_classes[i - 1]
			cur := report.clone_classes[i]
			testing.expect(t, prev.dedup_value >= cur.dedup_value, "JSON classes must be dedup-ranked")
			testing.expect_value(t, cur.rank, i + 1)
		}
	}
}

// test_report_no_clones_form pins the empty-input renderings: the human form is the
// "no clones found" line, and the JSON is a valid object whose clone_classes is an
// empty array (not null).
@(test)
test_report_no_clones_form :: proc(t: ^testing.T) {
	empty := []Clone_Class{}

	human := render_dup_human(empty, context.temp_allocator)
	testing.expect(t, strings.contains(human, "no clones found"), "an empty scan must say so")

	body := render_dup_json(empty, context.temp_allocator)
	testing.expect(
		t,
		strings.contains(body, "\"clone_classes\":[]"),
		"an empty scan's JSON must carry an empty clone_classes array",
	)

	report: Dup_Report
	err := json.unmarshal_string(body, &report, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "the empty JSON must still parse into Dup_Report")
	testing.expect_value(t, len(report.clone_classes), 0)
}
