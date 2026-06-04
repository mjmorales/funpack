// Trigonometric kernel over Fixed — polynomial evaluation in integer
// arithmetic, no libm and no float anywhere in the path (spec §10: the
// bit-identical transcendental contract). The cardinal values are exact
// by construction: an odd polynomial vanishes at zero and an even one
// with unit constant term yields exactly 1.0. Interior precision beyond
// the pinned cardinals is the golden-bits table seam (spec §10 Tier-1
// audit obligation).
package funpack

// PI_FIXED is the nearest Q32.32 to π: round(π · 2³²) =
// round(13493037704.52…) — a pinned constant, deterministic by
// definition rather than by computation.
PI_FIXED :: Fixed(13493037705)

// fixed_sin: x − x³/6 + x⁵/120, every term over the saturating kernel.
fixed_sin :: proc(angle: Fixed) -> Fixed {
	x2 := fixed_mul(angle, angle)
	x3 := fixed_mul(x2, angle)
	x5 := fixed_mul(x3, x2)
	result := fixed_sub(angle, fixed_div(x3, to_fixed(6)))
	return fixed_add(result, fixed_div(x5, to_fixed(120)))
}

// fixed_cos: 1 − x²/2 + x⁴/24, every term over the saturating kernel.
fixed_cos :: proc(angle: Fixed) -> Fixed {
	x2 := fixed_mul(angle, angle)
	x4 := fixed_mul(x2, x2)
	result := fixed_sub(FIXED_ONE, fixed_div(x2, to_fixed(2)))
	return fixed_add(result, fixed_div(x4, to_fixed(24)))
}
