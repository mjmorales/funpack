// Dup report-surface tests: the report turns the engine's []Clone_Class into leverage-ranked
// []Diagnostic, so its floor is (1) the leverage metrics — dedup_value and mass — are
// computed correctly, (2) rank_clone_classes orders by dedup_value descending and is a
// function of the class SET alone (shuffling the input yields the same order), (3)
// dup_diagnostics projects that ranking onto the diagnostic surface — highest-leverage class
// first, the metric in the message, the first site the primary and the rest related notes —
// and (4) the rendered projection does not leak the input order. The shared renderers'
// format/JSON/summary contract is pinned in eir_diagnostic_test.odin; here we pin only that
// dup projects ONTO it correctly. Classes are constructed directly so the report is pinned
// independent of the clone engine's hashing.
package eir

import "core:strings"
import "core:testing"

// site builds one Clone_Instance with the given location (non-test). col defaults to 0 — the
// projection's structure is what these tests pin, not a real source column.
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

// test_report_ranks_by_dedup_value_desc pins the ranking key: the ranked class list runs in
// dedup_value-descending order, which differs from both the hash and construction orders.
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
}

// test_dup_diagnostics_leverage_order pins the projection: the diagnostics run highest-leverage
// first, each message carries the clone kind and dedup value, the primary is the class's first
// site, and the remaining sites become related notes (a 3-site class has 2 related entries).
@(test)
test_dup_diagnostics_leverage_order :: proc(t: ^testing.T) {
	diags := dup_diagnostics(sample_classes(), .Warning, context.temp_allocator)
	testing.expect_value(t, len(diags), 3)
	if len(diags) == 3 {
		// Top class B (dedup 50) leads, primary at its first site d.odin:1.
		testing.expect_value(t, diags[0].file, "d.odin")
		testing.expect_value(t, diags[0].line, 1)
		testing.expect_value(t, diags[0].severity, Severity.Warning)
		testing.expect_value(t, diags[0].rule, "dup")
		testing.expect(t, strings.contains(diags[0].message, "proc_lit"), "the message carries the clone kind")
		testing.expect(t, strings.contains(diags[0].message, "dedup 50"), "the message carries the leverage metric")
		testing.expect_value(t, len(diags[0].related), 2) // 3 sites -> 2 related notes

		// Descending leverage: 50, 35, 20.
		testing.expect(t, strings.contains(diags[1].message, "dedup 35"), "second-highest leverage follows")
		testing.expect(t, strings.contains(diags[2].message, "dedup 20"), "lowest leverage is last")
	}
}

// test_report_projection_independent_of_input_order pins that the rendered projection is a
// function of the class SET: a reversed input yields byte-identical human and JSON output, so
// neither rendering leaks the construction order.
@(test)
test_report_projection_independent_of_input_order :: proc(t: ^testing.T) {
	forward := sample_classes()
	reversed := sample_classes()
	slice_reverse(reversed)

	human_forward := render_diagnostics_human(dup_diagnostics(forward, .Warning, context.temp_allocator), context.temp_allocator)
	human_reversed := render_diagnostics_human(dup_diagnostics(reversed, .Warning, context.temp_allocator), context.temp_allocator)
	testing.expect(t, human_forward == human_reversed, "the human stream must not depend on input order")

	json_forward := render_diagnostics_json(dup_diagnostics(forward, .Warning, context.temp_allocator), context.temp_allocator)
	json_reversed := render_diagnostics_json(dup_diagnostics(reversed, .Warning, context.temp_allocator), context.temp_allocator)
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
