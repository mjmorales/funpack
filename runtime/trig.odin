package funpack_runtime

PI_FIXED :: Fixed(13493037705)

TAU_FIXED :: Fixed(26986075409)

fixed_sin :: proc(angle: Fixed) -> Fixed {
	x2 := fixed_mul(angle, angle)
	x3 := fixed_mul(x2, angle)
	x5 := fixed_mul(x3, x2)
	result := fixed_sub(angle, fixed_div(x3, to_fixed(6)))
	return fixed_add(result, fixed_div(x5, to_fixed(120)))
}

fixed_cos :: proc(angle: Fixed) -> Fixed {
	x2 := fixed_mul(angle, angle)
	x4 := fixed_mul(x2, x2)
	result := fixed_sub(FIXED_ONE, fixed_div(x2, to_fixed(2)))
	return fixed_add(result, fixed_div(x4, to_fixed(24)))
}
