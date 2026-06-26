// Trigonometric kernel over Fixed — polynomial evaluation in integer
// arithmetic, no libm and no float anywhere in the path (spec §10: the
// bit-identical transcendental contract). The cardinal values are exact
// by construction: an odd polynomial vanishes at zero and an even one
// with unit constant term yields exactly 1.0. Interior precision beyond
// the pinned cardinals is the golden-bits table seam (spec §10 Tier-1
// audit obligation).
//
// PROVENANCE — this is the CANONICAL kernel; runtime/trig.odin is its
// DELIBERATE COPY (not a shared import: spec §29/§09 keep runtime/** and
// funpack/** separate products). The two kernels are byte-for-byte identical
// over the whole surface, enforced by the trig_test.odin cross-check (the
// runtime fixed_sin bits equal the funpack fixed_sin bits over the pinned
// cardinal angles). Any change here must be mirrored byte-for-byte into
// runtime/trig.odin or pose-driven replay diverges.
package funpack

// PI_FIXED is the nearest Q32.32 to π: round(π · 2³²) =
// round(13493037704.52…) — a pinned constant, deterministic by
// definition rather than by computation.
PI_FIXED :: Fixed(13493037705)

// TAU_FIXED is the nearest Q32.32 to τ (= 2π): round(τ · 2³²) =
// round(26986075409.05…) — the spec §10 "pi/tau (nearest-Fixed)" angle
// constant, pinned by definition. It is one ULP below 2·PI_FIXED (each
// rounds independently to its own nearest-Fixed), so it is a constant in its
// own right, never 2·PI_FIXED computed at runtime.
TAU_FIXED :: Fixed(26986075409)

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
