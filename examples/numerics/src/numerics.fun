@doc("The fixed-point numeric contract, pinned as golden assertions: type-directed literals, total saturating arithmetic, defined division by zero, exactness on representable values, integer-kernel trig, quaternion identity laws, and the left-to-right fold order. Every test is a plain function over plain values — the same bits on every machine (spec/10-numerics.md).")
import engine.prelude.Option
import engine.math.{Vec2, Vec3, Quat, clamp, lerp, dot, cross, length, sin, cos, to_fixed, trunc, floor, round, checked_div, pi}
import engine.list.fold

@doc("Numeric literals are type-directed: 42 is Int, 42.5 is Fixed. to_fixed lifts an Int into the fixed-point domain explicitly — there is no implicit promotion (numerics.md, AX1).")
test "literals and explicit conversion" {
  assert to_fixed(2) == 2.0
  assert to_fixed(2) + 0.5 == 2.5
}

@doc("Operations on binary-representable values are exact in Q32.32.")
test "exact fixed-point arithmetic" {
  assert 0.5 * 0.5 == 0.25
  assert 1.0 / 4.0 == 0.25
  assert 0.25 + 0.5 == 0.75
}

@doc("Arithmetic saturates at the rails — it never wraps (silently wrong) and never traps (a panic, AX4).")
test "overflow saturates, never wraps" {
  assert Fixed.MAX + 1.0 == Fixed.MAX
  assert Fixed.MIN - 1.0 == Fixed.MIN
}

@doc("Division by zero is a defined, sign-saturating value, so `/` stays a total operator — no trap, no Result to thread through every divide.")
test "division by zero is defined" {
  assert 1.0 / 0.0 == Fixed.MAX
  assert -1.0 / 0.0 == Fixed.MIN
  assert 0.0 / 0.0 == 0.0
  assert 5.0 % 0.0 == 0.0
}

@doc("When detecting a zero divisor is the point, checked_div returns an Option, forcing the match exactly where it matters.")
test "checked_div surfaces the zero divisor" {
  assert checked_div(6.0, 2.0) == Option::Some(3.0)
  assert checked_div(1.0, 0.0) == Option::None
}

@doc("Fixed→Int rounding is a fixed rule per function: trunc toward zero, floor toward negative infinity, round to nearest (ties away from zero).")
test "rounding conversions" {
  assert trunc(1.5) == 1
  assert trunc(-1.5) == -1
  assert floor(-1.5) == -2
  assert round(1.5) == 2
}

@doc("Selection and interpolation are total and exact on representable inputs.")
test "clamp and lerp" {
  assert clamp(5.0, 0.0, 3.0) == 3.0
  assert clamp(-1.0, 0.0, 3.0) == 0.0
  assert lerp(0.0, 10.0, 0.5) == 5.0
}

@doc("Vector ops are engine Num / free functions. The length of a 3-4-5 triangle is exactly 5 — fixed-point sqrt is exact on a perfect square.")
test "vector length, dot, and cross" {
  assert length(Vec2{x: 3.0, y: 4.0}) == 5.0
  assert dot(Vec2{x: 3.0, y: 4.0}, Vec2{x: 1.0, y: 0.0}) == 3.0
  assert cross(Vec3{x: 1.0, y: 0.0, z: 0.0}, Vec3{x: 0.0, y: 1.0, z: 0.0}) == Vec3{x: 0.0, y: 0.0, z: 1.0}
}

@doc("Trig is computed in integer arithmetic, exact at the cardinal angles and bit-identical on every machine — no libm, no float in the path (spec/10-numerics.md).")
test "trig at cardinal angles" {
  assert sin(0.0) == 0.0
  assert cos(0.0) == 1.0
}

@doc("Quaternion identity laws hold exactly (no trig involved): identity rotates a vector to itself, and composes as a unit.")
test "quaternion identity laws" {
  let v = Vec3{x: 1.0, y: 2.0, z: 3.0}
  assert Quat.identity.rotate(v) == v
  assert Quat.identity.mul(Quat.identity) == Quat.identity
}

@doc("slerp returns its endpoints exactly at t=0 and t=1 — the basis of bit-identical reconciliation, independent of pi's inexact representation.")
test "slerp endpoints are exact" {
  let a = Quat.identity
  let b = Quat.axis_angle(Vec3{x: 0.0, y: 0.0, z: 1.0}, pi)
  assert a.slerp(b, 0.0) == a
  assert a.slerp(b, 1.0) == b
}

@doc("Fixed-point + is not reorder-invariant under saturation, so the engine folds strictly left-to-right: (MAX + 1) saturates to MAX, then - 1 steps down to MAX - 1. A right fold would yield MAX (numerics.md, resolving iteration.md).")
test "fold is left-to-right under saturation" {
  assert fold([1.0, -1.0], Fixed.MAX, fn(acc, x) { return acc + x }) == Fixed.MAX - 1.0
}
