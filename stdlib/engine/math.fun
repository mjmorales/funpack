@doc("Numbers and space. Fixed-point throughout, so every result is sim-legal and replay-safe. The numeric free functions (length, dot, normalize, lerp) are engine-privileged: defined over the closed set of engine numeric types, since user code has neither generics nor overloading.")

import engine.prelude.{Fixed, Int}

@doc("A 2D vector in fixed logical units. Supports + - * (scalar and component-wise).")
data Vec2: Num { x: Fixed, y: Fixed }

@doc("A 3D vector in fixed logical units. Supports + - * (scalar and component-wise).")
data Vec3: Num { x: Fixed, y: Fixed, z: Fixed }

@doc("A unit quaternion orientation. Built via from_axis_angle / from_euler; composed with mul; interpolated with slerp.")
data Quat { x: Fixed, y: Fixed, z: Fixed, w: Fixed }

@doc("An axis-aligned bounding box.")
data Aabb { min: Vec3, max: Vec3 }

@doc("A 4x4 transform matrix. Opaque: built and combined through functions, never by field.")
extern type Mat4

@doc("The ratio of a circle's circumference to its diameter.")
let pi:  Fixed = 3.14159265
@doc("One full turn in radians (2*pi). The natural period for phase accumulators.")
let tau: Fixed = 6.28318531

@doc("Sine of an angle in radians. Fixed-point and bit-identical across machines.")
extern fn sin(x: Fixed) -> Fixed
@doc("Cosine of an angle in radians.")
extern fn cos(x: Fixed) -> Fixed
@doc("Tangent of an angle in radians.")
extern fn tan(x: Fixed) -> Fixed
@doc("Angle in radians of the vector (x, y), in (-pi, pi]. Quadrant-correct.")
extern fn atan2(y: Fixed, x: Fixed) -> Fixed
@doc("Non-negative square root. Defined for x >= 0.")
extern fn sqrt(x: Fixed) -> Fixed
@doc("Absolute value.")
extern fn abs(x: Fixed) -> Fixed
@doc("Largest integer-valued Fixed not greater than x.")
extern fn floor(x: Fixed) -> Fixed
@doc("Smallest integer-valued Fixed not less than x.")
extern fn ceil(x: Fixed) -> Fixed
@doc("Nearest integer-valued Fixed, ties away from zero.")
extern fn round(x: Fixed) -> Fixed
@doc("The smaller of two values.")
extern fn min(a: Fixed, b: Fixed) -> Fixed
@doc("The larger of two values.")
extern fn max(a: Fixed, b: Fixed) -> Fixed

@doc("Constrains x to [lo, hi]. Tier-2: composed over min/max.")
fn clamp(x: Fixed, lo: Fixed, hi: Fixed) -> Fixed {
  return min(max(x, lo), hi)
}

@doc("Linear interpolation from a to b by t in [0, 1]. Tier-2.")
fn lerp(a: Fixed, b: Fixed, t: Fixed) -> Fixed {
  return a + (b - a) * t
}

@doc("Euclidean length of a 2D vector. Tier-2 over sqrt.")
fn length(v: Vec2) -> Fixed {
  return sqrt(v.x * v.x + v.y * v.y)
}

@doc("Euclidean length of a 3D vector. Tier-2 over sqrt.")
fn length3(v: Vec3) -> Fixed {
  return sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
}

@doc("Dot product of two 3D vectors.")
fn dot(a: Vec3, b: Vec3) -> Fixed {
  return a.x * b.x + a.y * b.y + a.z * b.z
}

@doc("Cross product of two 3D vectors.")
extern fn cross(a: Vec3, b: Vec3) -> Vec3

@doc("A unit-length copy of v, or v unchanged if it is zero-length.")
extern fn normalize(v: Vec3) -> Vec3

@doc("An orientation of angle radians about a unit axis.")
extern fn from_axis_angle(axis: Vec3, angle: Fixed) -> Quat
@doc("An orientation from yaw/pitch/roll radians (Y, X, Z order).")
extern fn from_euler(yaw: Fixed, pitch: Fixed, roll: Fixed) -> Quat
@doc("Composes two orientations: apply b, then a.")
extern fn qmul(a: Quat, b: Quat) -> Quat
@doc("Shortest-path spherical interpolation between two orientations by t in [0, 1].")
extern fn slerp(a: Quat, b: Quat, t: Fixed) -> Quat
@doc("Rotates a vector by an orientation.")
extern fn rotate(q: Quat, v: Vec3) -> Vec3

@doc("The identity transform.")
extern fn mat_identity() -> Mat4
@doc("A transform from translation, rotation, and scale.")
extern fn mat_trs(translate: Vec3, rotate: Quat, scale: Vec3) -> Mat4
@doc("Composes two transforms: apply b, then a.")
extern fn mat_mul(a: Mat4, b: Mat4) -> Mat4
@doc("Applies a transform to a point.")
extern fn transform_point(m: Mat4, p: Vec3) -> Vec3
