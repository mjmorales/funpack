package funpack_runtime

import "core:testing"

ACT_STEER :: ActionId(0)
ACT_FIRE :: ActionId(1)
ACT_JUMP :: ActionId(2)

@(test)
test_empty_reads_all_zero :: proc(t: ^testing.T) {
	snap := empty()
	defer delete_input(snap)
	testing.expect(t, !pressed(snap, .P1, ACT_FIRE))
	testing.expect(t, !released(snap, .P1, ACT_FIRE))
	testing.expect(t, !held(snap, .P1, ACT_FIRE))
	testing.expect_value(t, value(snap, .P1, ACT_STEER), Fixed(0))
	testing.expect_value(t, axis(snap, .P1, ACT_STEER), VEC2_ZERO)
}

@(test)
test_unqueried_action_returns_default :: proc(t: ^testing.T) {
	snap := with_pressed(empty(), .P1, ACT_FIRE)
	defer delete_input(snap)
	testing.expect(t, pressed(snap, .P1, ACT_FIRE))
	testing.expect(t, !pressed(snap, .P1, ACT_JUMP))
	testing.expect_value(t, value(snap, .P1, ACT_STEER), Fixed(0))
	testing.expect(t, !pressed(snap, .P2, ACT_FIRE))
}

@(test)
test_with_pressed_implies_held_same_tick :: proc(t: ^testing.T) {
	snap := with_pressed(empty(), .P1, ACT_FIRE)
	defer delete_input(snap)
	testing.expect(t, pressed(snap, .P1, ACT_FIRE))
	testing.expect(t, held(snap, .P1, ACT_FIRE))
	testing.expect(t, !released(snap, .P1, ACT_FIRE))
}

@(test)
test_with_held_is_level_without_edge :: proc(t: ^testing.T) {
	snap := with_held(empty(), .P2, ACT_JUMP)
	defer delete_input(snap)
	testing.expect(t, held(snap, .P2, ACT_JUMP))
	testing.expect(t, !pressed(snap, .P2, ACT_JUMP))
	testing.expect(t, !released(snap, .P2, ACT_JUMP))
}

@(test)
test_with_value_reads_back_fixed :: proc(t: ^testing.T) {
	half := fixed_from_decimal(0, "5")
	snap := with_value(empty(), .P1, ACT_STEER, half)
	defer delete_input(snap)
	testing.expect_value(t, value(snap, .P1, ACT_STEER), half)
	testing.expect_value(t, axis(snap, .P1, ACT_STEER), Vec2{half, Fixed(0)})
}

@(test)
test_with_value_clamps_into_unit_range :: proc(t: ^testing.T) {
	hi := with_value(empty(), .P1, ACT_STEER, to_fixed(5))
	defer delete_input(hi)
	testing.expect_value(t, value(hi, .P1, ACT_STEER), to_fixed(1))

	lo := with_value(empty(), .P1, ACT_STEER, to_fixed(-5))
	defer delete_input(lo)
	testing.expect_value(t, value(lo, .P1, ACT_STEER), fixed_neg(to_fixed(1)))

	quarter := fixed_from_decimal(0, "25")
	mid := with_value(empty(), .P1, ACT_STEER, fixed_neg(quarter))
	defer delete_input(mid)
	testing.expect_value(t, value(mid, .P1, ACT_STEER), fixed_neg(quarter))
}

@(test)
test_with_axis_reads_back_clamped_both_components :: proc(t: ^testing.T) {
	snap := with_axis(empty(), .P3, ACT_STEER, Vec2{to_fixed(2), to_fixed(-3)})
	defer delete_input(snap)
	testing.expect_value(t, axis(snap, .P3, ACT_STEER), Vec2{to_fixed(1), fixed_neg(to_fixed(1))})
	testing.expect_value(t, value(snap, .P3, ACT_STEER), to_fixed(1))
}

@(test)
test_producers_are_immutable :: proc(t: ^testing.T) {
	base := empty()
	defer delete_input(base)
	derived := with_pressed(base, .P1, ACT_FIRE)
	defer delete_input(derived)
	testing.expect(t, !pressed(base, .P1, ACT_FIRE))
	testing.expect(t, pressed(derived, .P1, ACT_FIRE))
	derived2 := with_value(base, .P1, ACT_STEER, to_fixed(1))
	defer delete_input(derived2)
	testing.expect_value(t, value(base, .P1, ACT_STEER), Fixed(0))
	testing.expect_value(t, value(derived2, .P1, ACT_STEER), to_fixed(1))
}
