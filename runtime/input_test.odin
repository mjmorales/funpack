// Snapshot-core proof for the §23 input layer: the producer surface builds a
// snapshot, the query API reads it back, and the read obeys the spec invariants
// — clamp into [-1, 1] on construction (§23 §4), pressed implies held within a
// tick (§23 §2), an unqueried action returns the zero/false default (§23 §5),
// and Input.empty() reads all-zero (§23 §5). These are written in the exact
// device-free vocabulary §23 §5 demands; no Key/Pad/Mouse appears.
package funpack_runtime

import "core:testing"

// Stand-in action identities. The artifact loader (sibling story) will mint
// real ActionIds from enum variants (Steer::Move, Move::Up); the snapshot core
// is generic over identity, so the tests pick arbitrary stable ids — proving
// the core never depends on pong's enums.
ACT_STEER :: ActionId(0) // an Axis-kinded action stand-in
ACT_FIRE :: ActionId(1) // a Button-kinded action stand-in
ACT_JUMP :: ActionId(2)

@(test)
test_empty_reads_all_zero :: proc(t: ^testing.T) {
	// Input.empty() — every query returns its default across players and
	// actions (spec §23 §5).
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
	// A snapshot that touches ONE action leaves every other action at its
	// default — the absence-default IS the unqueried reading (spec §23 §5).
	snap := with_pressed(empty(), .P1, ACT_FIRE)
	defer delete_input(snap)
	// The touched action is set...
	testing.expect(t, pressed(snap, .P1, ACT_FIRE))
	// ...but an untouched action on the same player reads false/zero...
	testing.expect(t, !pressed(snap, .P1, ACT_JUMP))
	testing.expect_value(t, value(snap, .P1, ACT_STEER), Fixed(0))
	// ...and the same action on a different player is independent.
	testing.expect(t, !pressed(snap, .P2, ACT_FIRE))
}

@(test)
test_with_pressed_implies_held_same_tick :: proc(t: ^testing.T) {
	// §23 §2: a press is also down at the tick instant — pressed sets held
	// without the caller asking, but does NOT assert the released edge.
	snap := with_pressed(empty(), .P1, ACT_FIRE)
	defer delete_input(snap)
	testing.expect(t, pressed(snap, .P1, ACT_FIRE))
	testing.expect(t, held(snap, .P1, ACT_FIRE))
	testing.expect(t, !released(snap, .P1, ACT_FIRE))
}

@(test)
test_with_held_is_level_without_edge :: proc(t: ^testing.T) {
	// A button already down on the previous tick is held but NOT pressed this
	// tick — the level/edge distinction §23 §2 draws.
	snap := with_held(empty(), .P2, ACT_JUMP)
	defer delete_input(snap)
	testing.expect(t, held(snap, .P2, ACT_JUMP))
	testing.expect(t, !pressed(snap, .P2, ACT_JUMP))
	testing.expect(t, !released(snap, .P2, ACT_JUMP))
}

@(test)
test_with_value_reads_back_fixed :: proc(t: ^testing.T) {
	// with_value sets the 1D reading; value reads back the exact fixed-point
	// bits (spec §23 §2). The 1D reading is the Vec2 x component, so axis sees
	// it on x with y at zero.
	half := fixed_from_decimal(0, "5")
	snap := with_value(empty(), .P1, ACT_STEER, half)
	defer delete_input(snap)
	testing.expect_value(t, value(snap, .P1, ACT_STEER), half)
	testing.expect_value(t, axis(snap, .P1, ACT_STEER), Vec2{half, Fixed(0)})
}

@(test)
test_with_value_clamps_into_unit_range :: proc(t: ^testing.T) {
	// Construction clamps into [-1, 1] (spec §23 §4): an out-of-range producer
	// input is pinned to the rail, never stored past it.
	hi := with_value(empty(), .P1, ACT_STEER, to_fixed(5))
	defer delete_input(hi)
	testing.expect_value(t, value(hi, .P1, ACT_STEER), to_fixed(1))

	lo := with_value(empty(), .P1, ACT_STEER, to_fixed(-5))
	defer delete_input(lo)
	testing.expect_value(t, value(lo, .P1, ACT_STEER), fixed_neg(to_fixed(1)))

	// An in-range fractional value passes through unclamped, bit-exact.
	quarter := fixed_from_decimal(0, "25")
	mid := with_value(empty(), .P1, ACT_STEER, fixed_neg(quarter))
	defer delete_input(mid)
	testing.expect_value(t, value(mid, .P1, ACT_STEER), fixed_neg(quarter))
}

@(test)
test_with_axis_reads_back_clamped_both_components :: proc(t: ^testing.T) {
	// with_axis sets a 2D reading; axis reads back both components, each
	// independently clamped into [-1, 1] (spec §23 §4). The 1D value query
	// returns the clamped x.
	snap := with_axis(empty(), .P3, ACT_STEER, Vec2{to_fixed(2), to_fixed(-3)})
	defer delete_input(snap)
	testing.expect_value(t, axis(snap, .P3, ACT_STEER), Vec2{to_fixed(1), fixed_neg(to_fixed(1))})
	testing.expect_value(t, value(snap, .P3, ACT_STEER), to_fixed(1))
}

@(test)
test_producers_are_immutable :: proc(t: ^testing.T) {
	// Every with_* returns a NEW snapshot; the input it was handed is
	// unchanged (spec §23 §5: a snapshot a behavior holds can never mutate
	// underneath it). The base must stay all-zero after chaining off it.
	base := empty()
	defer delete_input(base)
	derived := with_pressed(base, .P1, ACT_FIRE)
	defer delete_input(derived)
	// base is untouched...
	testing.expect(t, !pressed(base, .P1, ACT_FIRE))
	// ...derived carries the press...
	testing.expect(t, pressed(derived, .P1, ACT_FIRE))
	// ...and chaining a second producer off base still does not disturb base.
	derived2 := with_value(base, .P1, ACT_STEER, to_fixed(1))
	defer delete_input(derived2)
	testing.expect_value(t, value(base, .P1, ACT_STEER), Fixed(0))
	testing.expect_value(t, value(derived2, .P1, ACT_STEER), to_fixed(1))
}

@(test)
test_keys_of_is_deterministically_ordered :: proc(t: ^testing.T) {
	// keys_of returns a canonical (player, action) order regardless of map
	// iteration order — the stable enumeration a later recorder digests
	// (spec §23 §4). Build out of order; expect sorted by player then action.
	// Each producer clones, so the intermediates are freed explicitly to keep
	// the leak-checked test allocator clean (a chain owns its intermediates).
	s0 := empty()
	defer delete_input(s0)
	s1 := with_pressed(s0, .P2, ACT_FIRE)
	defer delete_input(s1)
	s2 := with_pressed(s1, .P1, ACT_JUMP)
	defer delete_input(s2)
	snap := with_value(s2, .P1, ACT_STEER, to_fixed(1))
	defer delete_input(snap)
	keys := keys_of(snap)
	defer delete(keys)
	testing.expect_value(t, len(keys), 3)
	testing.expect_value(t, keys[0], Player_Action{.P1, ACT_STEER})
	testing.expect_value(t, keys[1], Player_Action{.P1, ACT_JUMP})
	testing.expect_value(t, keys[2], Player_Action{.P2, ACT_FIRE})
}
