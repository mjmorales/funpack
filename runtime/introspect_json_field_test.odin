package funpack_runtime

import "core:encoding/json"
import "core:testing"

@(test)
test_json_int_field_accepts_integral_float_rejects_fractional :: proc(t: ^testing.T) {
	obj := make(json.Object)
	defer delete(obj)
	obj["whole"] = json.Integer(42)
	obj["integral"] = json.Float(42.0)
	obj["fractional"] = json.Float(42.5)
	obj["text"] = json.String("42")

	whole, has_whole := json_int_field(obj, "whole")
	testing.expect(t, has_whole, "a json.Integer is read")
	testing.expect_value(t, whole, i64(42))

	integral, has_integral := json_int_field(obj, "integral")
	testing.expect(t, has_integral, "an integral json.Float (42.0) is accepted as the integer it names")
	testing.expect_value(t, integral, i64(42))

	_, has_fractional := json_int_field(obj, "fractional")
	testing.expect(t, !has_fractional, "a fractional float (42.5) is rejected, never truncated")

	_, has_text := json_int_field(obj, "text")
	testing.expect(t, !has_text, "a string is not a number")

	_, has_absent := json_int_field(obj, "absent")
	testing.expect(t, !has_absent, "an absent field is reported not-present")
}
