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
test_vec2_div_by_fixed_round_toward_zero :: proc(t: ^testing.T) {
	v := Vec2_Value{x = to_fixed(10), y = to_fixed(0)}
	testing.expect_value(t, vec2_div(v, to_fixed(10)), Vec2_Value{x = to_fixed(1), y = to_fixed(0)})
	delta := Vec2_Value{x = to_fixed(3), y = to_fixed(4)}
	speed := to_fixed(2)
	testing.expect_value(t, vec2_div(vec2_scale(delta, speed), speed), delta)
}

@(test)
test_quat_identity_laws :: proc(t: ^testing.T) {
	v := Vec3_Value{x = to_fixed(1), y = to_fixed(2), z = to_fixed(3)}
	testing.expect_value(t, quat_rotate(QUAT_IDENTITY, v), v)
	testing.expect_value(t, quat_mul(QUAT_IDENTITY, QUAT_IDENTITY), QUAT_IDENTITY)
}

@(test)
test_quat_slerp_endpoints_exact :: proc(t: ^testing.T) {
	a := QUAT_IDENTITY
	b := quat_axis_angle(Vec3_Value{z = FIXED_ONE}, PI_FIXED)
	testing.expect_value(t, quat_slerp(a, b, Fixed(0)), a)
	testing.expect_value(t, quat_slerp(a, b, FIXED_ONE), b)
}

@(test)
test_quat_axis_angle_deterministic_unit :: proc(t: ^testing.T) {
	first := quat_axis_angle(Vec3_Value{z = FIXED_ONE}, PI_FIXED)
	second := quat_axis_angle(Vec3_Value{z = FIXED_ONE}, PI_FIXED)
	testing.expect_value(t, first, second)
}

@(test)
test_pipeline_slerp_endpoint_golden_values :: proc(t: ^testing.T) {
	report, err := run_golden_asserts(
		"assert Quat.identity.slerp(Quat.axis_angle(Vec3{x: 0.0, y: 0.0, z: 1.0}, pi), 0.0) == Quat.identity\n" +
		"assert Quat.identity.slerp(Quat.axis_angle(Vec3{x: 0.0, y: 0.0, z: 1.0}, pi), 1.0) == Quat.axis_angle(Vec3{x: 0.0, y: 0.0, z: 1.0}, pi)\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
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
	report, err := run_golden_asserts(
		"assert Quat.identity.rotate(Vec3{x: 1.0, y: 2.0, z: 3.0}) == Vec3{x: 1.0, y: 2.0, z: 3.0}\n" +
		"assert Quat.identity.mul(Quat.identity) == Quat.identity\n")
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}
