// Fixed is the one sim number: signed 64-bit Q32.32 (spec §10), and this
// file is the saturating scalar kernel both Fixed and Int flow through.
// Total arithmetic, never wrap, never trap: overflow clamps to the
// MAX/MIN rails, division by zero is defined and sign-saturating
// (+x/0 → MAX, −x/0 → MIN, 0/0 → 0, x%0 → 0), and multiply/divide
// round toward zero over i128 intermediates. All-integer arithmetic —
// no float anywhere, so the bits are identical on every machine.
package funpack

Fixed :: distinct i64

FIXED_FRACTION_BITS :: 32

FIXED_MAX :: Fixed(max(i64))
FIXED_MIN :: Fixed(min(i64))

// to_fixed is the explicit Int → Fixed lift (spec §10: never implicit),
// saturating like every other operation.
to_fixed :: proc(n: i64) -> Fixed {
	return fixed_saturate(i128(n) << FIXED_FRACTION_BITS)
}

fixed_saturate :: proc(v: i128) -> Fixed {
	if v > i128(FIXED_MAX) {
		return FIXED_MAX
	}
	if v < i128(FIXED_MIN) {
		return FIXED_MIN
	}
	return Fixed(v)
}

fixed_add :: proc(a, b: Fixed) -> Fixed {
	return fixed_saturate(i128(a) + i128(b))
}

fixed_sub :: proc(a, b: Fixed) -> Fixed {
	return fixed_saturate(i128(a) - i128(b))
}

// fixed_mul shifts the 128-bit product back to Q32.32 with i128
// division rather than an arithmetic shift — shifting would round
// toward negative infinity for negative products; division truncates
// toward zero, the one rounding rule (spec §10).
fixed_mul :: proc(a, b: Fixed) -> Fixed {
	return fixed_saturate((i128(a) * i128(b)) / (i128(1) << FIXED_FRACTION_BITS))
}

fixed_div :: proc(a, b: Fixed) -> Fixed {
	if b == 0 {
		switch {
		case a > 0:
			return FIXED_MAX
		case a < 0:
			return FIXED_MIN
		}
		return Fixed(0)
	}
	return fixed_saturate((i128(a) << FIXED_FRACTION_BITS) / i128(b))
}

// fixed_mod is the truncated remainder a - trunc(a/b)*b, which over raw
// Q32.32 bits is exactly the integer remainder — no rescaling needed.
fixed_mod :: proc(a, b: Fixed) -> Fixed {
	if b == 0 {
		return Fixed(0)
	}
	return Fixed(i64(a) % i64(b))
}

fixed_neg :: proc(a: Fixed) -> Fixed {
	if a == FIXED_MIN {
		return FIXED_MAX
	}
	return -a
}

// Int shares the kernel's one rule: 64-bit signed, saturating, defined
// division by zero (spec §10 — no other integer widths exist).
INT_MAX :: max(i64)
INT_MIN :: min(i64)

int_saturate :: proc(v: i128) -> i64 {
	if v > i128(INT_MAX) {
		return INT_MAX
	}
	if v < i128(INT_MIN) {
		return INT_MIN
	}
	return i64(v)
}

int_add :: proc(a, b: i64) -> i64 {
	return int_saturate(i128(a) + i128(b))
}

int_sub :: proc(a, b: i64) -> i64 {
	return int_saturate(i128(a) - i128(b))
}

int_mul :: proc(a, b: i64) -> i64 {
	return int_saturate(i128(a) * i128(b))
}

int_div :: proc(a, b: i64) -> i64 {
	if b == 0 {
		switch {
		case a > 0:
			return INT_MAX
		case a < 0:
			return INT_MIN
		}
		return 0
	}
	return int_saturate(i128(a) / i128(b))
}

int_mod :: proc(a, b: i64) -> i64 {
	if b == 0 {
		return 0
	}
	return a % b
}

int_neg :: proc(a: i64) -> i64 {
	if a == INT_MIN {
		return INT_MAX
	}
	return -a
}

// fixed_sqrt is the integer square-root kernel: digit-by-digit binary
// restoring over u128, bit-exact on perfect squares (sqrt(25.0) is
// exactly 5.0) and floor-rounded otherwise. sqrt of Q32.32 bits b is
// isqrt(b << 32) because sqrt(b·2⁻³²)·2³² = sqrt(b·2³²). Total: a
// non-positive input yields zero.
fixed_sqrt :: proc(f: Fixed) -> Fixed {
	if f <= 0 {
		return Fixed(0)
	}
	n := u128(f) << FIXED_FRACTION_BITS
	bit := u128(1) << 126
	for bit > n {
		bit >>= 2
	}
	remainder := n
	result: u128 = 0
	for bit != 0 {
		if remainder >= result + bit {
			remainder -= result + bit
			result = (result >> 1) + bit
		} else {
			result >>= 1
		}
		bit >>= 2
	}
	return Fixed(i64(result))
}

// fixed_trunc rounds toward zero — i64 division truncates, so the raw
// bits over one whole unit give the rule directly.
fixed_trunc :: proc(f: Fixed) -> i64 {
	return i64(f) / (i64(1) << FIXED_FRACTION_BITS)
}

// fixed_floor rounds toward negative infinity — exactly what an
// arithmetic right shift does to two's-complement bits.
fixed_floor :: proc(f: Fixed) -> i64 {
	return i64(f) >> FIXED_FRACTION_BITS
}

// fixed_round rounds to nearest with ties away from zero: floor(|f| +
// 0.5) on the magnitude, sign reapplied, over i128 so the +0.5 cannot
// overflow near the rails.
fixed_round :: proc(f: Fixed) -> i64 {
	half := i128(1) << (FIXED_FRACTION_BITS - 1)
	if f >= 0 {
		return i64((i128(f) + half) >> FIXED_FRACTION_BITS)
	}
	return -i64((-i128(f) + half) >> FIXED_FRACTION_BITS)
}

fixed_clamp :: proc(x, lo, hi: Fixed) -> Fixed {
	if x < lo {
		return lo
	}
	if x > hi {
		return hi
	}
	return x
}

// fixed_abs is the saturating magnitude — negating through fixed_neg so the
// MIN rail maps to MAX rather than wrapping (spec §10: every operation is
// total and saturating).
fixed_abs :: proc(f: Fixed) -> Fixed {
	if f < 0 {
		return fixed_neg(f)
	}
	return f
}

// fixed_lerp is ordinary funpack over the saturating kernel:
// a + (b - a) * t (spec §10 Tier-2).
fixed_lerp :: proc(a, b, t: Fixed) -> Fixed {
	return fixed_add(a, fixed_mul(fixed_sub(b, a), t))
}

// fixed_checked_div surfaces the zero divisor instead of saturating —
// ok is false exactly when b == 0 (spec §10: detecting the zero divisor
// is the caller's point here).
fixed_checked_div :: proc(a, b: Fixed) -> (quotient: Fixed, ok: bool) {
	if b == 0 {
		return Fixed(0), false
	}
	return fixed_div(a, b), true
}

// fixed_from_decimal converts a literal's integer part and fractional
// digits to Q32.32 bits, rounding to nearest with ties up (spec §10:
// deterministic compile-time rounding). All-integer arithmetic — no float
// anywhere in the path, so the bits are identical on every machine — and
// exact for ANY digit count: the fraction's leading FIXED_FRACTION_BITS+1
// bits are extracted by repeated decimal doubling (the carry out of the
// digit array is the next bit, most significant first), so no intermediate
// ever exceeds one decimal digit per position. The capture-to-test exporter
// renders exact dyadic decimals up to 32 fractional digits; a fixed-width
// numerator would overflow at ~29 (2^96 < numer·2^32), silently corrupting
// a round-trip of those literals.
fixed_from_decimal :: proc(int_part: i64, frac_digits: string) -> Fixed {
	stack: [64]u8
	digits := stack[:min(len(frac_digits), len(stack))]
	if len(frac_digits) > len(stack) {
		digits = make([]u8, len(frac_digits), context.temp_allocator)
	}
	for i in 0 ..< len(frac_digits) {
		digits[i] = frac_digits[i] - '0'
	}
	// floor(x·2^33) for the decimal fraction x, one doubling per bit.
	bits: u64 = 0
	for _ in 0 ..< FIXED_FRACTION_BITS + 1 {
		carry: u8 = 0
		for i := len(digits) - 1; i >= 0; i -= 1 {
			doubled := digits[i]*2 + carry
			digits[i] = doubled % 10
			carry = doubled / 10
		}
		bits = bits<<1 | u64(carry)
	}
	// Round half up off the extra bit: floor(x·2^32 + 1/2) = (floor(x·2^33)+1)>>1.
	frac_bits := (bits + 1) >> 1
	return Fixed((int_part << FIXED_FRACTION_BITS) + i64(frac_bits))
}
