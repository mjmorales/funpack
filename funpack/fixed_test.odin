package funpack

import "core:testing"

@(test)
test_to_fixed_lifts_int :: proc(t: ^testing.T) {
	testing.expect_value(t, to_fixed(2), Fixed(2 << 32))
	testing.expect_value(t, to_fixed(0), Fixed(0))
}

@(test)
test_fixed_from_decimal_exact_bits :: proc(t: ^testing.T) {
	testing.expect_value(t, fixed_from_decimal(2, "0"), to_fixed(2))
	testing.expect_value(t, fixed_from_decimal(0, "5"), Fixed(1 << 31)) // 0.5
	testing.expect_value(t, fixed_from_decimal(2, "5"), Fixed(5 << 31)) // 2.5
}

@(test)
test_fixed_from_decimal_rounds_to_nearest :: proc(t: ^testing.T) {
	// 0.1 is not representable in Q32.32; spec §10 mandates
	// deterministic round-to-nearest: 2^32/10 = 429496729.6 → 429496730.
	testing.expect_value(t, fixed_from_decimal(0, "1"), Fixed(429496730))
}

@(test)
test_fixed_from_decimal_long_literal_boundary :: proc(t: ^testing.T) {
	// The capture-to-test exporter renders exact dyadic Q32.32 decimals up
	// to 32 fractional digits; these must round-trip to their exact bits
	// (a fixed-width numerator overflows at ~29 digits, 2^96 < numer·2^32,
	// so the boundary pins the digit-doubling kernel's exactness).
	testing.expect_value(t, fixed_from_decimal(0, "00000000023283064365386962890625"), Fixed(1)) // 2^-32
	testing.expect_value(t, fixed_from_decimal(0, "99999999976716935634613037109375"), Fixed(4294967295)) // (2^32-1)/2^32
	testing.expect_value(t, fixed_from_decimal(1, "99999999976716935634613037109375"), Fixed(1 << 32 | 4294967295))
}

@(test)
test_fixed_from_decimal_beyond_32_digits_rounds :: proc(t: ^testing.T) {
	// Digits beyond the 32 dyadic places only steer rounding: 1.5·2^-32 (33
	// digits) is the exact tie and rounds up; one ulp-of-decimal below it
	// rounds down; 2^-33 (the half of one fraction bit) ties up to 1.
	testing.expect_value(t, fixed_from_decimal(0, "000000000349245965480804443359375"), Fixed(2))
	testing.expect_value(t, fixed_from_decimal(0, "0000000003492459654808044433593749999"), Fixed(1))
	testing.expect_value(t, fixed_from_decimal(0, "000000000116415321826934814453125"), Fixed(1))
}

@(test)
test_fixed_from_decimal_past_stack_buffer :: proc(t: ^testing.T) {
	// A fraction longer than the 64-digit stack buffer takes the allocated
	// path and stays exact: 0.5 followed by a tail of zeros is still 2^31.
	long_half := "5" + "0000000000000000000000000000000000000000000000000000000000000000000000"
	testing.expect_value(t, fixed_from_decimal(0, long_half), Fixed(1 << 31))
}

@(test)
test_fixed_add_saturates_at_rails :: proc(t: ^testing.T) {
	testing.expect_value(t, fixed_add(FIXED_MAX, to_fixed(1)), FIXED_MAX)
	testing.expect_value(t, fixed_sub(FIXED_MIN, to_fixed(1)), FIXED_MIN)
	testing.expect_value(t, fixed_add(to_fixed(1), to_fixed(2)), to_fixed(3))
}

@(test)
test_fixed_mul_exact_and_toward_zero :: proc(t: ^testing.T) {
	half := fixed_from_decimal(0, "5")
	quarter := fixed_from_decimal(0, "25")
	testing.expect_value(t, fixed_mul(half, half), quarter)
	// Sub-precision products truncate toward zero in both signs: an
	// arithmetic shift would give -1 (toward negative infinity) for the
	// negative case.
	testing.expect_value(t, fixed_mul(Fixed(1), Fixed(1)), Fixed(0))
	testing.expect_value(t, fixed_mul(Fixed(-1), Fixed(1)), Fixed(0))
}

@(test)
test_fixed_div_exact_and_toward_zero :: proc(t: ^testing.T) {
	quarter := fixed_from_decimal(0, "25")
	testing.expect_value(t, fixed_div(to_fixed(1), to_fixed(4)), quarter)
	// -1/3 truncates toward zero: -1431655765, not the floor -1431655766.
	testing.expect_value(t, fixed_div(to_fixed(-1), to_fixed(3)), Fixed(-1431655765))
}

@(test)
test_fixed_div_by_zero_is_defined :: proc(t: ^testing.T) {
	testing.expect_value(t, fixed_div(to_fixed(1), Fixed(0)), FIXED_MAX)
	testing.expect_value(t, fixed_div(to_fixed(-1), Fixed(0)), FIXED_MIN)
	testing.expect_value(t, fixed_div(Fixed(0), Fixed(0)), Fixed(0))
	testing.expect_value(t, fixed_mod(to_fixed(5), Fixed(0)), Fixed(0))
}

@(test)
test_fixed_neg_saturates_min :: proc(t: ^testing.T) {
	testing.expect_value(t, fixed_neg(FIXED_MIN), FIXED_MAX)
	testing.expect_value(t, fixed_neg(to_fixed(2)), to_fixed(-2))
}

@(test)
test_int_kernel_saturates :: proc(t: ^testing.T) {
	testing.expect_value(t, int_add(INT_MAX, 1), INT_MAX)
	testing.expect_value(t, int_mul(INT_MAX, 2), INT_MAX)
	testing.expect_value(t, int_div(1, 0), INT_MAX)
	testing.expect_value(t, int_div(-1, 0), INT_MIN)
	testing.expect_value(t, int_div(0, 0), 0)
	testing.expect_value(t, int_mod(5, 0), 0)
	testing.expect_value(t, int_neg(INT_MIN), INT_MAX)
}

@(test)
test_fixed_rounding_conversions :: proc(t: ^testing.T) {
	one_half := fixed_from_decimal(1, "5")
	testing.expect_value(t, fixed_trunc(one_half), 1)
	testing.expect_value(t, fixed_trunc(fixed_neg(one_half)), -1)
	testing.expect_value(t, fixed_floor(fixed_neg(one_half)), -2)
	testing.expect_value(t, fixed_round(one_half), 2)
	testing.expect_value(t, fixed_round(fixed_neg(one_half)), -2)
	// Ties away from zero, not banker's rounding: 2.5 → 3.
	testing.expect_value(t, fixed_round(fixed_from_decimal(2, "5")), 3)
}

@(test)
test_fixed_clamp_and_lerp :: proc(t: ^testing.T) {
	testing.expect_value(t, fixed_clamp(to_fixed(5), to_fixed(0), to_fixed(3)), to_fixed(3))
	testing.expect_value(t, fixed_clamp(to_fixed(-1), to_fixed(0), to_fixed(3)), to_fixed(0))
	testing.expect_value(t, fixed_clamp(to_fixed(2), to_fixed(0), to_fixed(3)), to_fixed(2))
	half := fixed_from_decimal(0, "5")
	testing.expect_value(t, fixed_lerp(to_fixed(0), to_fixed(10), half), to_fixed(5))
}

@(test)
test_fixed_checked_div :: proc(t: ^testing.T) {
	quotient, ok := fixed_checked_div(to_fixed(6), to_fixed(2))
	testing.expect(t, ok)
	testing.expect_value(t, quotient, to_fixed(3))
	_, zero_ok := fixed_checked_div(to_fixed(1), Fixed(0))
	testing.expect(t, !zero_ok)
}

@(test)
test_to_fixed_saturates :: proc(t: ^testing.T) {
	// |n| ≥ 2^31 has no Q32.32 representation — the lift saturates like
	// every other kernel operation.
	testing.expect_value(t, to_fixed(i64(1) << 40), FIXED_MAX)
	testing.expect_value(t, to_fixed(-(i64(1) << 40)), FIXED_MIN)
}
