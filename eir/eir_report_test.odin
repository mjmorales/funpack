package eir

import "core:strings"
import "core:testing"

@(private = "file")
site :: proc(path: string, line_start, line_end: int) -> Clone_Instance {
	return Clone_Instance{path = path, is_test = false, line_start = line_start, line_end = line_end}
}

@(private = "file")
cls :: proc(hash: u64, node_count: int, kind: string, sites: ..Clone_Instance) -> Clone_Class {
	owned := make([]Clone_Instance, len(sites), context.temp_allocator)
	copy(owned, sites)
	return Clone_Class{hash = hash, node_count = node_count, kind = kind, instances = owned}
}

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

@(test)
test_report_dedup_value_and_mass :: proc(t: ^testing.T) {
	c := cls(0xD4, 12, "block", site("x.odin", 1, 5), site("y.odin", 7, 11), site("z.odin", 13, 17))
	testing.expect_value(t, class_dedup_value(c), 24)
	testing.expect_value(t, class_mass(c), 36)
}

@(test)
test_report_ranks_by_dedup_value_desc :: proc(t: ^testing.T) {
	ranked := rank_clone_classes(sample_classes(), context.temp_allocator)

	testing.expect_value(t, len(ranked), 3)
	testing.expect_value(t, ranked[0].hash, u64(0xB2))
	testing.expect_value(t, ranked[1].hash, u64(0xC3))
	testing.expect_value(t, ranked[2].hash, u64(0xA1))

	for i in 1 ..< len(ranked) {
		testing.expect(
			t,
			class_dedup_value(ranked[i - 1]) >= class_dedup_value(ranked[i]),
			"ranked classes must be in dedup_value-descending order",
		)
	}
}

@(test)
test_dup_diagnostics_leverage_order :: proc(t: ^testing.T) {
	diags := dup_diagnostics(sample_classes(), .Warning, context.temp_allocator)
	testing.expect_value(t, len(diags), 3)
	if len(diags) == 3 {
		testing.expect_value(t, diags[0].file, "d.odin")
		testing.expect_value(t, diags[0].line, 1)
		testing.expect_value(t, diags[0].severity, Severity.Warning)
		testing.expect_value(t, diags[0].rule, "dup")
		testing.expect(t, strings.contains(diags[0].message, "proc_lit"), "the message carries the clone kind")
		testing.expect(t, strings.contains(diags[0].message, "dedup 50"), "the message carries the leverage metric")
		testing.expect_value(t, len(diags[0].related), 2)

		testing.expect(t, strings.contains(diags[1].message, "dedup 35"), "second-highest leverage follows")
		testing.expect(t, strings.contains(diags[2].message, "dedup 20"), "lowest leverage is last")
	}
}

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

@(private = "file")
slice_reverse :: proc(s: []Clone_Class) {
	for i in 0 ..< len(s) / 2 {
		j := len(s) - 1 - i
		s[i], s[j] = s[j], s[i]
	}
}
