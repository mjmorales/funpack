// Vector and quaternion math over the saturating Fixed kernel — all
// integer arithmetic, component-wise bit-exact. The operator set
// mirrors spec §10: dot/cross/length are named functions, never
// operators; rotation composes through quat_mul, which renormalizes
// its result so a composed orientation stays unit (exact on the
// identity, where the norm is exactly 1.0 and the scale divides out).
package funpack

Vec2_Value :: struct {
	x, y: Fixed,
}

Vec3_Value :: struct {
	x, y, z: Fixed,
}

Quat_Value :: struct {
	x, y, z, w: Fixed,
}

FIXED_ONE :: Fixed(i64(1) << FIXED_FRACTION_BITS)

QUAT_IDENTITY :: Quat_Value{x = Fixed(0), y = Fixed(0), z = Fixed(0), w = FIXED_ONE}

// vec2_add / vec2_sub are component-wise over the saturating Fixed kernel —
// the `at + vel*dt` form the pong `advance` helper takes (spec §10: vector
// arithmetic is component-wise, each lane through the same scalar rule).
vec2_add :: proc(a, b: Vec2_Value) -> Vec2_Value {
	return Vec2_Value{x = fixed_add(a.x, b.x), y = fixed_add(a.y, b.y)}
}

vec2_sub :: proc(a, b: Vec2_Value) -> Vec2_Value {
	return Vec2_Value{x = fixed_sub(a.x, b.x), y = fixed_sub(a.y, b.y)}
}

// vec2_scale scales each component by a Fixed scalar — the `vel * dt` form.
vec2_scale :: proc(v: Vec2_Value, s: Fixed) -> Vec2_Value {
	return Vec2_Value{x = fixed_mul(v.x, s), y = fixed_mul(v.y, s)}
}

// vec2_div divides each component by a Fixed scalar through the SAME §10
// round-toward-zero fixed_div kernel vec2_scale uses for mul — the
// `(delta * speed) / d` form step_to takes after the multiply-before-divide
// reorder. Per-lane bit-exact: each component is an independent fixed_div, so
// `(10,0) / 10.0 == (1.0, 0)` and the zero-scalar saturation is fixed_div's.
vec2_div :: proc(v: Vec2_Value, s: Fixed) -> Vec2_Value {
	return Vec2_Value{x = fixed_div(v.x, s), y = fixed_div(v.y, s)}
}

vec3_add :: proc(a, b: Vec3_Value) -> Vec3_Value {
	return Vec3_Value{x = fixed_add(a.x, b.x), y = fixed_add(a.y, b.y), z = fixed_add(a.z, b.z)}
}

vec3_sub :: proc(a, b: Vec3_Value) -> Vec3_Value {
	return Vec3_Value{x = fixed_sub(a.x, b.x), y = fixed_sub(a.y, b.y), z = fixed_sub(a.z, b.z)}
}

vec3_scale :: proc(v: Vec3_Value, s: Fixed) -> Vec3_Value {
	return Vec3_Value{x = fixed_mul(v.x, s), y = fixed_mul(v.y, s), z = fixed_mul(v.z, s)}
}

vec2_dot :: proc(a, b: Vec2_Value) -> Fixed {
	return fixed_add(fixed_mul(a.x, b.x), fixed_mul(a.y, b.y))
}

vec3_dot :: proc(a, b: Vec3_Value) -> Fixed {
	return fixed_add(fixed_add(fixed_mul(a.x, b.x), fixed_mul(a.y, b.y)), fixed_mul(a.z, b.z))
}

vec3_cross :: proc(a, b: Vec3_Value) -> Vec3_Value {
	return Vec3_Value{
		x = fixed_sub(fixed_mul(a.y, b.z), fixed_mul(a.z, b.y)),
		y = fixed_sub(fixed_mul(a.z, b.x), fixed_mul(a.x, b.z)),
		z = fixed_sub(fixed_mul(a.x, b.y), fixed_mul(a.y, b.x)),
	}
}

vec2_length :: proc(v: Vec2_Value) -> Fixed {
	return fixed_sqrt(vec2_dot(v, v))
}

vec3_length :: proc(v: Vec3_Value) -> Fixed {
	return fixed_sqrt(vec3_dot(v, v))
}

// quat_mul is the Hamilton product followed by renormalization, so a
// composed orientation is always unit (spec §10). The identity
// composition stays bit-exact: its norm is exactly 1.0, and dividing
// by sqrt(1.0) is the identity operation.
quat_mul :: proc(a, b: Quat_Value) -> Quat_Value {
	raw := Quat_Value{
		x = fixed_sub(fixed_add(fixed_add(fixed_mul(a.w, b.x), fixed_mul(a.x, b.w)), fixed_mul(a.y, b.z)), fixed_mul(a.z, b.y)),
		y = fixed_add(fixed_sub(fixed_add(fixed_mul(a.w, b.y), fixed_mul(a.y, b.w)), fixed_mul(a.x, b.z)), fixed_mul(a.z, b.x)),
		z = fixed_sub(fixed_add(fixed_add(fixed_mul(a.w, b.z), fixed_mul(a.z, b.w)), fixed_mul(a.x, b.y)), fixed_mul(a.y, b.x)),
		w = fixed_sub(fixed_sub(fixed_sub(fixed_mul(a.w, b.w), fixed_mul(a.x, b.x)), fixed_mul(a.y, b.y)), fixed_mul(a.z, b.z)),
	}
	return quat_normalize(raw)
}

quat_normalize :: proc(q: Quat_Value) -> Quat_Value {
	norm_sq := fixed_add(
		fixed_add(fixed_mul(q.x, q.x), fixed_mul(q.y, q.y)),
		fixed_add(fixed_mul(q.z, q.z), fixed_mul(q.w, q.w)),
	)
	norm := fixed_sqrt(norm_sq)
	if norm == 0 || norm == FIXED_ONE {
		return q
	}
	return Quat_Value{
		x = fixed_div(q.x, norm),
		y = fixed_div(q.y, norm),
		z = fixed_div(q.z, norm),
		w = fixed_div(q.w, norm),
	}
}

// quat_axis_angle builds the rotation of `angle` radians about `axis`:
// q = (â·sin(θ/2), cos(θ/2)) with the axis normalized first (total —
// a zero axis yields a zero vector part) and the result renormalized.
quat_axis_angle :: proc(axis: Vec3_Value, angle: Fixed) -> Quat_Value {
	length := vec3_length(axis)
	unit := axis
	if length != 0 && length != FIXED_ONE {
		unit = Vec3_Value{
			x = fixed_div(axis.x, length),
			y = fixed_div(axis.y, length),
			z = fixed_div(axis.z, length),
		}
	}
	half := fixed_div(angle, to_fixed(2))
	s := fixed_sin(half)
	c := fixed_cos(half)
	return quat_normalize(Quat_Value{
		x = fixed_mul(unit.x, s),
		y = fixed_mul(unit.y, s),
		z = fixed_mul(unit.z, s),
		w = c,
	})
}

// quat_slerp returns its endpoints by identity — t=0 yields a and t=1
// yields b bit-exactly, with no recomputation, independent of any
// constant's inexact representation. The interior is nlerp
// (component-wise lerp, renormalized), the default interpolation
// (spec §10).
quat_slerp :: proc(a, b: Quat_Value, t: Fixed) -> Quat_Value {
	if t == 0 {
		return a
	}
	if t == FIXED_ONE {
		return b
	}
	return quat_normalize(Quat_Value{
		x = fixed_lerp(a.x, b.x, t),
		y = fixed_lerp(a.y, b.y, t),
		z = fixed_lerp(a.z, b.z, t),
		w = fixed_lerp(a.w, b.w, t),
	})
}

// quat_rotate applies v' = v + 2w·(q⃗ × v) + 2·(q⃗ × (q⃗ × v)) — the
// expansion of q v q* that needs no division. With the identity's zero
// vector part both cross terms vanish, so v returns bit-exactly.
quat_rotate :: proc(q: Quat_Value, v: Vec3_Value) -> Vec3_Value {
	axis := Vec3_Value{x = q.x, y = q.y, z = q.z}
	two := to_fixed(2)
	t := vec3_cross(axis, v)
	t = Vec3_Value{x = fixed_mul(t.x, two), y = fixed_mul(t.y, two), z = fixed_mul(t.z, two)}
	cross_t := vec3_cross(axis, t)
	return Vec3_Value{
		x = fixed_add(fixed_add(v.x, fixed_mul(q.w, t.x)), cross_t.x),
		y = fixed_add(fixed_add(v.y, fixed_mul(q.w, t.y)), cross_t.y),
		z = fixed_add(fixed_add(v.z, fixed_mul(q.w, t.z)), cross_t.z),
	}
}
