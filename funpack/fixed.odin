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

// fixed_from_decimal converts a literal's integer part and fractional
// digits to Q32.32 bits, rounding to nearest (spec §10: deterministic
// compile-time rounding). All-integer arithmetic — no float anywhere in
// the path, so the bits are identical on every machine.
fixed_from_decimal :: proc(int_part: i64, frac_digits: string) -> Fixed {
	numer: u128 = 0
	denom: u128 = 1
	for ch in frac_digits {
		numer = numer*10 + u128(ch - '0')
		denom *= 10
	}
	frac_bits := u64((numer << FIXED_FRACTION_BITS + denom/2) / denom)
	return Fixed((int_part << FIXED_FRACTION_BITS) + i64(frac_bits))
}
