package funpack

import "core:testing"

@(test)
test_fixed_sqrt_exact_on_perfect_squares :: proc(t: ^testing.T) {
	testing.expect_value(t, fixed_sqrt(to_fixed(25)), to_fixed(5))
	testing.expect_value(t, fixed_sqrt(to_fixed(4)), to_fixed(2))
	testing.expect_value(t, fixed_sqrt(FIXED_ONE), FIXED_ONE)
	testing.expect_value(t, fixed_sqrt(fixed_from_decimal(0, "25")), fixed_from_decimal(0, "5"))
	testing.expect_value(t, fixed_sqrt(Fixed(0)), Fixed(0))
	testing.expect_value(t, fixed_sqrt(to_fixed(-4)), Fixed(0))
}

@(test)
test_vec_dot_cross_length :: proc(t: ^testing.T) {
	a := Vec2_Value{x = to_fixed(3), y = to_fixed(4)}
	testing.expect_value(t, vec2_length(a), to_fixed(5))
	testing.expect_value(t, vec2_dot(a, Vec2_Value{x = to_fixed(1), y = to_fixed(0)}), to_fixed(3))
	x_hat := Vec3_Value{x = FIXED_ONE}
	y_hat := Vec3_Value{y = FIXED_ONE}
	z_hat := Vec3_Value{z = FIXED_ONE}
	testing.expect_value(t, vec3_cross(x_hat, y_hat), z_hat)
}

@(test)
test_quat_identity_laws :: proc(t: ^testing.T) {
	v := Vec3_Value{x = to_fixed(1), y = to_fixed(2), z = to_fixed(3)}
	testing.expect_value(t, quat_rotate(QUAT_IDENTITY, v), v)
	testing.expect_value(t, quat_mul(QUAT_IDENTITY, QUAT_IDENTITY), QUAT_IDENTITY)
}

@(test)
test_pipeline_vector_golden_values :: proc(t: ^testing.T) {
	report, err := run_golden_asserts(
		"assert length(Vec2{x: 3.0, y: 4.0}) == 5.0\n" +
		"assert dot(Vec2{x: 3.0, y: 4.0}, Vec2{x: 1.0, y: 0.0}) == 3.0\n" +
		"assert cross(Vec3{x: 1.0, y: 0.0, z: 0.0}, Vec3{x: 0.0, y: 1.0, z: 0.0}) == Vec3{x: 0.0, y: 0.0, z: 1.0}\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_pipeline_quaternion_identity_golden_values :: proc(t: ^testing.T) {
	// The golden block binds v with let; until the environment lands the
	// same laws are pinned with the literal inlined.
	report, err := run_golden_asserts(
		"assert Quat.identity.rotate(Vec3{x: 1.0, y: 2.0, z: 3.0}) == Vec3{x: 1.0, y: 2.0, z: 3.0}\n" +
		"assert Quat.identity.mul(Quat.identity) == Quat.identity\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}
