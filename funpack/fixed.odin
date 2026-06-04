// Fixed is the one sim number: signed 64-bit Q32.32 (spec §10). This
// seam carries only the representation, the explicit Int lift, and
// decimal-literal conversion; the saturating arithmetic surface
// (spec §10) widens it behind the same names.
package funpack

Fixed :: distinct i64

FIXED_FRACTION_BITS :: 32

// to_fixed is the explicit Int → Fixed lift (spec §10: never implicit).
to_fixed :: proc(n: i64) -> Fixed {
	return Fixed(n << FIXED_FRACTION_BITS)
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
