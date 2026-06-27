package funpack

Fixed :: distinct i64

FIXED_FRACTION_BITS :: 32

FIXED_MAX :: Fixed(max(i64))
FIXED_MIN :: Fixed(min(i64))

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

fixed_trunc :: proc(f: Fixed) -> i64 {
	return i64(f) / (i64(1) << FIXED_FRACTION_BITS)
}

fixed_floor :: proc(f: Fixed) -> i64 {
	return i64(f) >> FIXED_FRACTION_BITS
}

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

fixed_abs :: proc(f: Fixed) -> Fixed {
	if f < 0 {
		return fixed_neg(f)
	}
	return f
}

fixed_lerp :: proc(a, b, t: Fixed) -> Fixed {
	return fixed_add(a, fixed_mul(fixed_sub(b, a), t))
}

fixed_checked_div :: proc(a, b: Fixed) -> (quotient: Fixed, ok: bool) {
	if b == 0 {
		return Fixed(0), false
	}
	return fixed_div(a, b), true
}

fixed_from_decimal :: proc(int_part: i64, frac_digits: string) -> Fixed {
	stack: [64]u8
	digits := stack[:min(len(frac_digits), len(stack))]
	if len(frac_digits) > len(stack) {
		digits = make([]u8, len(frac_digits), context.temp_allocator)
	}
	for i in 0 ..< len(frac_digits) {
		digits[i] = frac_digits[i] - '0'
	}
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
	frac_bits := (bits + 1) >> 1
	return Fixed((int_part << FIXED_FRACTION_BITS) + i64(frac_bits))
}
