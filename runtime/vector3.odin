// 3D vector and quaternion math over the saturating Fixed kernel — all integer
// arithmetic, component-wise bit-exact (spec §10: dot/cross/length are named
// functions, never operators; rotation composes through quat_mul, which
// renormalizes so a composed orientation stays unit).
//
// PROVENANCE — this is a DELIBERATE COPY of funpack/vector.odin's Vec3/Quat
// surface, NOT a shared import. runtime/** and funpack/** are separate products
// (spec §29, §09); the artifact file is the only sanctioned coupling, so
// runtime/** must never link compiler internals. The two surfaces carry a
// bit-identity OBLIGATION to each other (same Q32.32 bits for every pose
// transform) — the bet pose-driven replay is bit-identical, the same kernel-copy-
// not-link invariant the trig kernel (trig.odin) rides. Any change here must be
// mirrored byte-for-byte in funpack/vector.odin or the products diverge.
//
// SOURCING DELTA from the funpack original: funpack/vector.odin also declares
// FIXED_ONE and Vec2_Value here; this copy DROPS both — runtime/** already pins
// FIXED_ONE in fixed.odin (under the same kernel-copy obligation, task 1.2's
// FIXED_ONE coupling) and Vec2 in input.odin, so re-declaring either would be a
// duplicate-symbol error. The runtime spells the vector types bare (Vec2, Vec3,
// Quat), matching input.odin/state.odin, where funpack spells them *_Value.
package funpack_runtime

// Vec3 is a three-Fixed vector — the §10 Num kind in 3D: a world position, a
// bone's local translation, a rotation axis. No float ever (spec §10).
Vec3 :: struct {
	x, y, z: Fixed,
}

// Quat is a four-Fixed unit quaternion — a §16 §7 bone orientation. The identity
// (QUAT_IDENTITY) is the rest rotation a pose assigns an undriven bone.
Quat :: struct {
	x, y, z, w: Fixed,
}

// QUAT_IDENTITY is the rest rotation: a zero vector part and a unit scalar — the
// rotation rot_x(0.0) builds and the orientation Pose.get returns for an undriven
// bone. Its norm is exactly 1.0, so quat_normalize is the identity on it.
QUAT_IDENTITY :: Quat{x = Fixed(0), y = Fixed(0), z = Fixed(0), w = FIXED_ONE}

// vec3_add / vec3_sub are component-wise over the saturating Fixed kernel.
vec3_add :: proc(a, b: Vec3) -> Vec3 {
	return Vec3{x = fixed_add(a.x, b.x), y = fixed_add(a.y, b.y), z = fixed_add(a.z, b.z)}
}

vec3_sub :: proc(a, b: Vec3) -> Vec3 {
	return Vec3{x = fixed_sub(a.x, b.x), y = fixed_sub(a.y, b.y), z = fixed_sub(a.z, b.z)}
}

// vec3_scale multiplies each component by a Fixed scalar.
vec3_scale :: proc(v: Vec3, s: Fixed) -> Vec3 {
	return Vec3{x = fixed_mul(v.x, s), y = fixed_mul(v.y, s), z = fixed_mul(v.z, s)}
}

// vec3_dot is the §10 dot product over the kernel: ax*bx + ay*by + az*bz.
vec3_dot :: proc(a, b: Vec3) -> Fixed {
	return fixed_add(fixed_add(fixed_mul(a.x, b.x), fixed_mul(a.y, b.y)), fixed_mul(a.z, b.z))
}

// vec3_cross is the §10 cross product over the kernel.
vec3_cross :: proc(a, b: Vec3) -> Vec3 {
	return Vec3{
		x = fixed_sub(fixed_mul(a.y, b.z), fixed_mul(a.z, b.y)),
		y = fixed_sub(fixed_mul(a.z, b.x), fixed_mul(a.x, b.z)),
		z = fixed_sub(fixed_mul(a.x, b.y), fixed_mul(a.y, b.x)),
	}
}

// vec3_length is sqrt(dot(v, v)) through the kernel's integer sqrt — bit-exact on
// a perfect square, floor-rounded otherwise, no libm/float on the path (§10.5).
vec3_length :: proc(v: Vec3) -> Fixed {
	return fixed_sqrt(vec3_dot(v, v))
}

// vec3_lerp interpolates two vectors component-wise over the saturating kernel —
// each lane through fixed_lerp (spec §10: vector arithmetic is component-wise).
vec3_lerp :: proc(a, b: Vec3, t: Fixed) -> Vec3 {
	return Vec3{
		x = fixed_lerp(a.x, b.x, t),
		y = fixed_lerp(a.y, b.y, t),
		z = fixed_lerp(a.z, b.z, t),
	}
}

// quat_mul is the Hamilton product followed by renormalization, so a composed
// orientation is always unit (spec §10). The identity composition stays bit-exact:
// its norm is exactly 1.0, and dividing by sqrt(1.0) is the identity operation.
quat_mul :: proc(a, b: Quat) -> Quat {
	raw := Quat{
		x = fixed_sub(fixed_add(fixed_add(fixed_mul(a.w, b.x), fixed_mul(a.x, b.w)), fixed_mul(a.y, b.z)), fixed_mul(a.z, b.y)),
		y = fixed_add(fixed_sub(fixed_add(fixed_mul(a.w, b.y), fixed_mul(a.y, b.w)), fixed_mul(a.x, b.z)), fixed_mul(a.z, b.x)),
		z = fixed_sub(fixed_add(fixed_add(fixed_mul(a.w, b.z), fixed_mul(a.z, b.w)), fixed_mul(a.x, b.y)), fixed_mul(a.y, b.x)),
		w = fixed_sub(fixed_sub(fixed_sub(fixed_mul(a.w, b.w), fixed_mul(a.x, b.x)), fixed_mul(a.y, b.y)), fixed_mul(a.z, b.z)),
	}
	return quat_normalize(raw)
}

// quat_normalize scales a quaternion to unit length, leaving the identity (norm
// exactly 1.0) and the zero quaternion untouched bit-for-bit.
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

// quat_axis_angle builds the rotation of `angle` radians about `axis`:
// q = (â·sin(θ/2), cos(θ/2)) with the axis normalized first (a zero axis yields a
// zero vector part) and the result renormalized. At angle 0 the vector part is
// zero (sin(0)=0) and the scalar is 1.0 (cos(0)=1), so it is exactly the identity.
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

// quat_slerp returns its endpoints by identity — t=0 yields a and t=1 yields b
// bit-exactly, with no recomputation, independent of any constant's inexact
// representation. The interior is nlerp (component-wise lerp, renormalized), the
// default interpolation (spec §10). This is why Pose.blend at weight 0/1 reads the
// base/overlaid bone's orientation exactly (the funpack pose golden's anchor).
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
