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
