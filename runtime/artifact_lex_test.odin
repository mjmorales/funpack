// Lexical-layer proof (docs/artifact-format.md §2, §17): the primitive decoders
// and the single lead-line section reader. These pin the reader contract the
// loader is built on — the byte layout is unambiguous because every field is
// positionally typed and length-explicit and every record count is the lead-line
// count.
package funpack_runtime

import "core:strings"
import "core:testing"

// The primitive decoders read each field by the kind the caller knows from
// position (§2.2–§2.6). A Fixed decodes to its raw Q32.32 bits with no decimal
// point and no float (§2.3).
@(test)
test_primitive_decoders :: proc(t: ^testing.T) {
	// Int: signed decimal (§2.2).
	n, n_ok := decode_int("-7")
	testing.expect(t, n_ok)
	testing.expect_value(t, n, i64(-7))

	// Fixed: raw Q32.32 i64 bits, lifted straight into the kernel Fixed (§2.3).
	fx, fx_ok := decode_fixed("652835028992") // 152.0
	testing.expect(t, fx_ok)
	testing.expect_value(t, fx, to_fixed(152))
	neg, neg_ok := decode_fixed("-300647710720") // -70.0
	testing.expect(t, neg_ok)
	testing.expect_value(t, neg, fixed_neg(to_fixed(70)))

	// String: length-prefixed Lk:bytes, empty is L0: (§2.4).
	s, s_ok := decode_string("L15:Move the paddle")
	testing.expect(t, s_ok)
	testing.expect_value(t, s, "Move the paddle")
	empty, empty_ok := decode_string("L0:")
	testing.expect(t, empty_ok)
	testing.expect_value(t, empty, "")
	// A byte count that disagrees with the body length is refused.
	_, bad_ok := decode_string("L3:ab")
	testing.expect(t, !bad_ok)

	// Bool: bare lowercase token (§2.5).
	b, b_ok := decode_bool("true")
	testing.expect(t, b_ok)
	testing.expect(t, b)
	_, not_bool := decode_bool("TRUE")
	testing.expect(t, !not_bool)
}

// The §28 debug surfaces decode Fixed in HUMAN mode: a source-literal `110.0` lands on
// the same Q32.32 bits a funpack literal would, decoded float-free through
// fixed_from_decimal, while a bare integer still reads as raw bits and the artifact
// LOAD path (human=false) is untouched. This pins the round-trip: every value
// write_source_fixed renders decodes back to the IDENTICAL bits via decode_fixed(human).
@(test)
test_decode_fixed_human_source_literal :: proc(t: ^testing.T) {
	// Source-literal decimals decode to the literal's bits (not as raw bits).
	whole, whole_ok := decode_fixed("152.0", true)
	testing.expect(t, whole_ok)
	testing.expect_value(t, whole, to_fixed(152))
	half, half_ok := decode_fixed("0.5", true)
	testing.expect(t, half_ok)
	testing.expect_value(t, half, fixed_div(FIXED_ONE, to_fixed(2)))
	neg, neg_ok := decode_fixed("-0.5", true)
	testing.expect(t, neg_ok)
	testing.expect_value(t, neg, fixed_neg(fixed_div(FIXED_ONE, to_fixed(2))))

	// In human mode a bare integer is STILL raw Q32.32 bits — the dot discriminates, so
	// an older raw payload keeps decoding alongside the new decimal spelling.
	raw, raw_ok := decode_fixed("652835028992", true) // 152.0's bits
	testing.expect(t, raw_ok)
	testing.expect_value(t, raw, to_fixed(152))

	// The load path (human=false) NEVER reads a decimal as a value — `152.0` is not a
	// raw-bits integer, so it refuses rather than silently float-parsing (spec §2.3).
	_, load_ok := decode_fixed("152.0")
	testing.expect(t, !load_ok)

	// Round-trip closure: write_source_fixed → decode_fixed(human) reproduces the bits
	// for a battery spanning whole, dyadic-fraction, negative, and tiny-denominator values.
	cases := []Fixed {
		to_fixed(0),
		to_fixed(1),
		fixed_neg(to_fixed(70)),
		fixed_div(FIXED_ONE, to_fixed(2)), // 0.5
		fixed_div(FIXED_ONE, to_fixed(4)), // 0.25
		fixed_add(to_fixed(104), fixed_div(FIXED_ONE, to_fixed(8))), // 104.125
		Fixed(1), // smallest positive — 1 raw bit
	}
	for value in cases {
		b := strings.builder_make(context.temp_allocator)
		write_source_fixed(&b, value)
		decoded, ok := decode_fixed(strings.to_string(b), true)
		testing.expect(t, ok, strings.to_string(b))
		testing.expect_value(t, decoded, value)
	}
}

// The lead-line discipline (§2.1): a sub-record keyword is not a lead line, so a
// section's record count is the lead-line count.
@(test)
test_lead_line_discipline :: proc(t: ^testing.T) {
	testing.expect(t, is_lead_line("enum Side - 2"))
	testing.expect(t, is_lead_line("function advance fn 3 return:Vec2 1 span:pong:50"))
	testing.expect(t, !is_lead_line("variant Left unit")) // sub-record
	testing.expect(t, !is_lead_line("field w Fixed -")) // sub-record
	testing.expect(t, !is_lead_line("node return 1")) // sub-record (a body line)
	testing.expect(t, !is_lead_line("[enums 2]")) // section header opens with [
	testing.expect(t, !is_lead_line("")) // empty
}

// A section splits into exactly N records by the lead-line discipline, and a
// declared N that disagrees with the lead-line count is refused (§2.1, §17).
@(test)
test_section_count_exact_match :: proc(t: ^testing.T) {
	// A minimal two-enum section: 2 lead lines, each with one sub-record.
	content := "funpack-artifact 18\n[enums 2]\nenum A - 1\nvariant X unit\nenum B - 1\nvariant Y unit\n"
	doc, err := parse_artifact(content, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, len(doc.sections), 1)
	testing.expect_value(t, doc.sections[0].name, "enums")
	testing.expect_value(t, doc.sections[0].count, 2)
	testing.expect_value(t, len(doc.sections[0].records), 2)
	// The first record's lead line and its one sub-record.
	testing.expect_value(t, doc.sections[0].records[0].lead, "enum A - 1")
	testing.expect_value(t, len(doc.sections[0].records[0].subs), 1)
	testing.expect_value(t, doc.sections[0].records[0].subs[0], "variant X unit")

	// A declared N greater than the lead-line count is an under-shaped section.
	bad := "funpack-artifact 18\n[enums 3]\nenum A - 1\nvariant X unit\n"
	_, bad_err := parse_artifact(bad, context.temp_allocator)
	testing.expect_value(t, bad_err, Artifact_Error.Section_Count_Mismatch)
}

// A zero-record section still emits its header and has no body lines (§3) — a
// parser always reads a fixed sequence of headers.
@(test)
test_empty_section_header :: proc(t: ^testing.T) {
	content := "funpack-artifact 18\n[signals 0]\n[enums 1]\nenum A - 0\n"
	doc, err := parse_artifact(content, context.temp_allocator)
	testing.expect_value(t, err, Artifact_Error.None)
	testing.expect_value(t, len(doc.sections), 2)
	testing.expect_value(t, doc.sections[0].name, "signals")
	testing.expect_value(t, doc.sections[0].count, 0)
	testing.expect_value(t, len(doc.sections[0].records), 0)
}
