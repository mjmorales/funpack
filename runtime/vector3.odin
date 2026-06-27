package funpack_runtime

Vec3 :: struct {
	x, y, z: Fixed,
}

Quat :: struct {
	x, y, z, w: Fixed,
}

QUAT_IDENTITY :: Quat{x = Fixed(0), y = Fixed(0), z = Fixed(0), w = FIXED_ONE}

vec3_add :: proc(a, b: Vec3) -> Vec3 {
	return Vec3{x = fixed_add(a.x, b.x), y = fixed_add(a.y, b.y), z = fixed_add(a.z, b.z)}
}

vec3_sub :: proc(a, b: Vec3) -> Vec3 {
	return Vec3{x = fixed_sub(a.x, b.x), y = fixed_sub(a.y, b.y), z = fixed_sub(a.z, b.z)}
}

vec3_scale :: proc(v: Vec3, s: Fixed) -> Vec3 {
	return Vec3{x = fixed_mul(v.x, s), y = fixed_mul(v.y, s), z = fixed_mul(v.z, s)}
}

vec3_dot :: proc(a, b: Vec3) -> Fixed {
	return fixed_add(fixed_add(fixed_mul(a.x, b.x), fixed_mul(a.y, b.y)), fixed_mul(a.z, b.z))
}

vec3_cross :: proc(a, b: Vec3) -> Vec3 {
	return Vec3{
		x = fixed_sub(fixed_mul(a.y, b.z), fixed_mul(a.z, b.y)),
		y = fixed_sub(fixed_mul(a.z, b.x), fixed_mul(a.x, b.z)),
		z = fixed_sub(fixed_mul(a.x, b.y), fixed_mul(a.y, b.x)),
	}
}

vec3_length :: proc(v: Vec3) -> Fixed {
	return fixed_sqrt(vec3_dot(v, v))
}

vec3_lerp :: proc(a, b: Vec3, t: Fixed) -> Vec3 {
	return Vec3{
		x = fixed_lerp(a.x, b.x, t),
		y = fixed_lerp(a.y, b.y, t),
		z = fixed_lerp(a.z, b.z, t),
	}
}

quat_mul :: proc(a, b: Quat) -> Quat {
	raw := Quat{
		x = fixed_sub(fixed_add(fixed_add(fixed_mul(a.w, b.x), fixed_mul(a.x, b.w)), fixed_mul(a.y, b.z)), fixed_mul(a.z, b.y)),
		y = fixed_add(fixed_sub(fixed_add(fixed_mul(a.w, b.y), fixed_mul(a.y, b.w)), fixed_mul(a.x, b.z)), fixed_mul(a.z, b.x)),
		z = fixed_sub(fixed_add(fixed_add(fixed_mul(a.w, b.z), fixed_mul(a.z, b.w)), fixed_mul(a.x, b.y)), fixed_mul(a.y, b.x)),
		w = fixed_sub(fixed_sub(fixed_sub(fixed_mul(a.w, b.w), fixed_mul(a.x, b.x)), fixed_mul(a.y, b.y)), fixed_mul(a.z, b.z)),
	}
	return quat_normalize(raw)
}

quat_normalize :: proc(q: Quat) -> Quat {
	norm_sq := fixed_add(
		fixed_add(fixed_mul(q.x, q.x), fixed_mul(q.y, q.y)),
		fixed_add(fixed_mul(q.z, q.z), fixed_mul(q.w, q.w)),
	)
	norm := fixed_sqrt(norm_sq)
	if norm == 0 || norm == FIXED_ONE {
		return q
	}
	return Quat{
		x = fixed_div(q.x, norm),
		y = fixed_div(q.y, norm),
		z = fixed_div(q.z, norm),
		w = fixed_div(q.w, norm),
	}
}

quat_axis_angle :: proc(axis: Vec3, angle: Fixed) -> Quat {
	length := vec3_length(axis)
	unit := axis
	if length != 0 && length != FIXED_ONE {
		unit = Vec3{
			x = fixed_div(axis.x, length),
			y = fixed_div(axis.y, length),
			z = fixed_div(axis.z, length),
		}
	}
	half := fixed_div(angle, to_fixed(2))
	s := fixed_sin(half)
	c := fixed_cos(half)
	return quat_normalize(Quat{
		x = fixed_mul(unit.x, s),
		y = fixed_mul(unit.y, s),
		z = fixed_mul(unit.z, s),
		w = c,
	})
}

quat_slerp :: proc(a, b: Quat, t: Fixed) -> Quat {
	if t == 0 {
		return a
	}
	if t == FIXED_ONE {
		return b
	}
	return quat_normalize(Quat{
		x = fixed_lerp(a.x, b.x, t),
		y = fixed_lerp(a.y, b.y, t),
		z = fixed_lerp(a.z, b.z, t),
		w = fixed_lerp(a.w, b.w, t),
	})
}
