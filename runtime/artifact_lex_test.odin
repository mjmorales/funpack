package funpack_runtime

import "core:strings"
import "core:testing"

@(test)
test_primitive_decoders :: proc(t: ^testing.T) {
	n, n_ok := decode_int("-7")
	testing.expect(t, n_ok)
	testing.expect_value(t, n, i64(-7))

	fx, fx_ok := decode_fixed("652835028992")
	testing.expect(t, fx_ok)
	testing.expect_value(t, fx, to_fixed(152))
	neg, neg_ok := decode_fixed("-300647710720")
	testing.expect(t, neg_ok)
	testing.expect_value(t, neg, fixed_neg(to_fixed(70)))

	s, s_ok := decode_string("L15:Move the paddle")
	testing.expect(t, s_ok)
	testing.expect_value(t, s, "Move the paddle")
	empty, empty_ok := decode_string("L0:")
	testing.expect(t, empty_ok)
	testing.expect_value(t, empty, "")
	_, bad_ok := decode_string("L3:ab")
	testing.expect(t, !bad_ok)

	b, b_ok := decode_bool("true")
	testing.expect(t, b_ok)
	testing.expect(t, b)
	_, not_bool := decode_bool("TRUE")
	testing.expect(t, !not_bool)
}

@(test)
test_decode_fixed_human_source_literal :: proc(t: ^testing.T) {
	whole, whole_ok := decode_fixed("152.0", true)
	testing.expect(t, whole_ok)
	testing.expect_value(t, whole, to_fixed(152))
	half, half_ok := decode_fixed("0.5", true)
	testing.expect(t, half_ok)
	testing.expect_value(t, half, fixed_div(FIXED_ONE, to_fixed(2)))
	neg, neg_ok := decode_fixed("-0.5", true)
	testing.expect(t, neg_ok)
	testing.expect_value(t, neg, fixed_neg(fixed_div(FIXED_ONE, to_fixed(2))))

	raw, raw_ok := decode_fixed("652835028992", true)
	testing.expect(t, raw_ok)
	testing.expect_value(t, raw, to_fixed(152))

	_, load_ok := decode_fixed("152.0")
	testing.expect(t, !load_ok)

	cases := []Fixed {
		to_fixed(0),
		to_fixed(1),
		fixed_neg(to_fixed(70)),
		fixed_div(FIXED_ONE, to_fixed(2)),
		fixed_div(FIXED_ONE, to_fixed(4)),
		fixed_add(to_fixed(104), fixed_div(FIXED_ONE, to_fixed(8))),
		Fixed(1),
	}
	for value in cases {
		b := strings.builder_make(context.temp_allocator)
		write_source_fixed(&b, value)
		decoded, ok := decode_fixed(strings.to_string(b), true)
		testing.expect(t, ok, strings.to_string(b))
		testing.expect_value(t, decoded, value)
	}
}

@(test)
test_lead_line_discipline :: proc(t: ^testing.T) {
	testing.expect(t, is_lead_line("enum Side - 2"))
	testing.expect(t, is_lead_line("function advance fn 3 return:Vec2 1 span:pong:50"))
	testing.expect(t, !is_lead_line("variant Left unit"))
	testing.expect(t, !is_lead_line("field w Fixed -"))
	testing.expect(t, !is_lead_line("node return 1"))
	testing.expect(t, !is_lead_line("[enums 2]"))
	testing.expect(t, !is_lead_line(""))
}

@(test)
test_section_count_exact_match :: proc(t: ^testing.T) {
	content := "funpack-artifact 19\n[enums 2]\nenum A - 1\nvariant X unit\nenum B - 1\nvariant Y unit\n"
	doc, err := parse_artifact(content, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, len(doc.sections), 1)
	testing.expect_value(t, doc.sections[0].name, "enums")
	testing.expect_value(t, doc.sections[0].count, 2)
	testing.expect_value(t, len(doc.sections[0].records), 2)
	testing.expect_value(t, doc.sections[0].records[0].lead, "enum A - 1")
	testing.expect_value(t, len(doc.sections[0].records[0].subs), 1)
	testing.expect_value(t, doc.sections[0].records[0].subs[0], "variant X unit")

	bad := "funpack-artifact 19\n[enums 3]\nenum A - 1\nvariant X unit\n"
	_, bad_err := parse_artifact(bad, context.temp_allocator)
	testing.expect_value(t, bad_err, Artifact_Error.Section_Count_Mismatch)
}

@(test)
test_empty_section_header :: proc(t: ^testing.T) {
	content := "funpack-artifact 19\n[signals 0]\n[enums 1]\nenum A - 0\n"
	doc, err := parse_artifact(content, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, len(doc.sections), 2)
	testing.expect_value(t, doc.sections[0].name, "signals")
	testing.expect_value(t, doc.sections[0].count, 0)
	testing.expect_value(t, len(doc.sections[0].records), 0)
}
