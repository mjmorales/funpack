package funpack_runtime

import "core:testing"

Fixed_Op :: enum {
	Add,
	Sub,
	Mul,
	Div,
	Mod,
	Neg,
}

Fixed_Golden :: struct {
	op:       Fixed_Op,
	a, b:     Fixed,
	expected: Fixed,
	note:     string,
}

apply_fixed_op :: proc(v: Fixed_Golden) -> Fixed {
	switch v.op {
	case .Add:
		return fixed_add(v.a, v.b)
	case .Sub:
		return fixed_sub(v.a, v.b)
	case .Mul:
		return fixed_mul(v.a, v.b)
	case .Div:
		return fixed_div(v.a, v.b)
	case .Mod:
		return fixed_mod(v.a, v.b)
	case .Neg:
		return fixed_neg(v.a)
	}
	return Fixed(0)
}

@(test)
test_shared_golden_bit_identity :: proc(t: ^testing.T) {
	half := fixed_from_decimal(0, "5")
	quarter := fixed_from_decimal(0, "25")
	golden := [?]Fixed_Golden {
		{.Add, FIXED_MAX, to_fixed(1), FIXED_MAX, "MAX + 1 saturates"},
		{.Sub, FIXED_MIN, to_fixed(1), FIXED_MIN, "MIN - 1 saturates"},
		{.Add, to_fixed(1), to_fixed(2), to_fixed(3), "1 + 2 = 3"},
		{.Mul, half, half, quarter, "0.5 * 0.5 = 0.25 exact"},
		{.Mul, Fixed(1), Fixed(1), Fixed(0), "sub-precision truncates toward zero (+)"},
		{.Mul, Fixed(-1), Fixed(1), Fixed(0), "sub-precision truncates toward zero (-)"},
		{.Div, to_fixed(1), to_fixed(4), quarter, "1 / 4 = 0.25 exact"},
		{.Div, to_fixed(-1), to_fixed(3), Fixed(-1431655765), "-1/3 truncates toward zero, not floor"},
		{.Div, to_fixed(1), Fixed(0), FIXED_MAX, "+x / 0 = MAX"},
		{.Div, to_fixed(-1), Fixed(0), FIXED_MIN, "-x / 0 = MIN"},
		{.Div, Fixed(0), Fixed(0), Fixed(0), "0 / 0 = 0"},
		{.Mod, to_fixed(5), Fixed(0), Fixed(0), "x % 0 = 0"},
		{.Neg, FIXED_MIN, Fixed(0), FIXED_MAX, "neg(MIN) = MAX"},
		{.Neg, to_fixed(2), Fixed(0), to_fixed(-2), "neg(2) = -2"},
	}
	for v in golden {
		got := apply_fixed_op(v)
		testing.expectf(
			t,
			got == v.expected,
			"golden %v (%s): got %d, want %d",
			v.op,
			v.note,
			i64(got),
			i64(v.expected),
		)
	}
}

@(test)
test_to_fixed_lifts_int :: proc(t: ^testing.T) {
	testing.expect_value(t, to_fixed(2), Fixed(2 << 32))
	testing.expect_value(t, to_fixed(0), Fixed(0))
}

@(test)
test_to_fixed_saturates :: proc(t: ^testing.T) {
	testing.expect_value(t, to_fixed(i64(1) << 40), FIXED_MAX)
	testing.expect_value(t, to_fixed(-(i64(1) << 40)), FIXED_MIN)
}

@(test)
test_fixed_from_decimal_exact_bits :: proc(t: ^testing.T) {
	testing.expect_value(t, fixed_from_decimal(2, "0"), to_fixed(2))
	testing.expect_value(t, fixed_from_decimal(0, "5"), Fixed(1 << 31))
	testing.expect_value(t, fixed_from_decimal(2, "5"), Fixed(5 << 31))
}

@(test)
test_fixed_from_decimal_rounds_to_nearest :: proc(t: ^testing.T) {
	testing.expect_value(t, fixed_from_decimal(0, "1"), Fixed(429496730))
}

@(test)
test_fixed_from_decimal_long_literal_boundary :: proc(t: ^testing.T) {
	testing.expect_value(t, fixed_from_decimal(0, "00000000023283064365386962890625"), Fixed(1))
	testing.expect_value(t, fixed_from_decimal(0, "99999999976716935634613037109375"), Fixed(4294967295))
	testing.expect_value(t, fixed_from_decimal(1, "99999999976716935634613037109375"), Fixed(1 << 32 | 4294967295))
	testing.expect_value(t, fixed_from_decimal(0, "000000000349245965480804443359375"), Fixed(2))
	testing.expect_value(t, fixed_from_decimal(0, "0000000003492459654808044433593749999"), Fixed(1))
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
	testing.expect_value(t, fixed_mul(Fixed(1), Fixed(1)), Fixed(0))
	testing.expect_value(t, fixed_mul(Fixed(-1), Fixed(1)), Fixed(0))
}

@(test)
test_fixed_div_exact_and_toward_zero :: proc(t: ^testing.T) {
	quarter := fixed_from_decimal(0, "25")
	testing.expect_value(t, fixed_div(to_fixed(1), to_fixed(4)), quarter)
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
test_fixed_ceil_toward_positive_infinity :: proc(t: ^testing.T) {
	one_half := fixed_from_decimal(1, "5")
	testing.expect_value(t, fixed_ceil(one_half), 2)
	testing.expect_value(t, fixed_ceil(fixed_neg(one_half)), -1)
	testing.expect_value(t, fixed_ceil(to_fixed(3)), 3)
}

@(test)
test_fixed_checked_rem :: proc(t: ^testing.T) {
	remainder, ok := fixed_checked_rem(to_fixed(5), to_fixed(3))
	testing.expect(t, ok)
	testing.expect_value(t, remainder, to_fixed(2))
	_, zero_ok := fixed_checked_rem(to_fixed(1), Fixed(0))
	testing.expect(t, !zero_ok)
}

@(test)
test_fixed_sqrt_integer_kernel :: proc(t: ^testing.T) {
	testing.expect_value(t, fixed_sqrt(to_fixed(25)), to_fixed(5))
	testing.expect_value(t, fixed_sqrt(to_fixed(4)), to_fixed(2))
	testing.expect_value(t, fixed_sqrt(to_fixed(0)), Fixed(0))
	testing.expect_value(t, fixed_sqrt(to_fixed(-9)), Fixed(0))
	testing.expect_value(t, fixed_sqrt(fixed_from_decimal(0, "25")), fixed_from_decimal(0, "5"))
}
