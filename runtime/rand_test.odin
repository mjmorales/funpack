package funpack_runtime

import "core:testing"

RAND_SEED_42_NEXT := [5]i64 {
	-4767286540954276203,
	2949826092126892291,
	5139283748462763858,
	6349198060258255764,
	701532786141963250,
}

@(test)
test_rand_next_golden_sequence :: proc(t: ^testing.T) {
	rng := rand_seed(42)
	for want, i in RAND_SEED_42_NEXT {
		got, next := rand_next(rng)
		testing.expectf(
			t,
			got == want,
			"next draw[%d]: got %d, want %d",
			i,
			got,
			want,
		)
		rng = next
	}
}

@(test)
test_rand_same_seed_reproduces_sequence :: proc(t: ^testing.T) {
	a := rand_seed(1234)
	b := rand_seed(1234)
	for i in 0 ..< 16 {
		va, na := rand_next(a)
		vb, nb := rand_next(b)
		testing.expectf(t, va == vb, "draw[%d] diverged: %d vs %d", i, va, vb)
		testing.expectf(t, na.state == nb.state, "state[%d] diverged", i)
		a = na
		b = nb
	}
}

@(test)
test_rand_different_seed_diverges :: proc(t: ^testing.T) {
	v0, _ := rand_next(rand_seed(0))
	v1, _ := rand_next(rand_seed(1))
	v42, _ := rand_next(rand_seed(42))
	testing.expect_value(t, v0, -2152535657050944081)
	testing.expect_value(t, v1, -7995527694508729151)
	testing.expect(t, v0 != v1)
	testing.expect(t, v0 != v42)
	testing.expect(t, v1 != v42)
}

RAND_SEED_42_BOUNDED_10 := [8]int{7, 1, 2, 3, 0, 8, 2, 8}

@(test)
test_rand_bounded_golden_indices :: proc(t: ^testing.T) {
	rng := rand_seed(42)
	for want, i in RAND_SEED_42_BOUNDED_10 {
		got, next := rand_bounded(rng, 10)
		testing.expectf(t, got == want, "bounded idx[%d]: got %d, want %d", i, got, want)
		testing.expect(t, got >= 0 && got < 10)
		rng = next
	}
}

@(test)
test_rand_bounded_advances_in_lockstep_with_next :: proc(t: ^testing.T) {
	rng := rand_seed(999)
	_, after_next := rand_next(rng)
	_, after_bounded := rand_bounded(rng, 6)
	testing.expect_value(t, after_bounded.state, after_next.state)
}

@(test)
test_rand_pick_some_selects_in_range :: proc(t: ^testing.T) {
	list := []int{100, 200, 300, 400, 500, 600, 700, 800, 900, 1000}
	rng := rand_seed(42)
	for want_idx, i in RAND_SEED_42_BOUNDED_10 {
		element, ok, next := rand_pick(list, rng)
		testing.expectf(t, ok, "pick[%d] returned None on a non-empty list", i)
		testing.expectf(
			t,
			element == list[want_idx],
			"pick[%d]: got %d, want %d (list[%d])",
			i,
			element,
			list[want_idx],
			want_idx,
		)
		rng = next
	}
}

@(test)
test_rand_pick_empty_is_none_but_advances :: proc(t: ^testing.T) {
	empty := []int{}
	rng := rand_seed(42)
	element, ok, next := rand_pick(empty, rng)
	testing.expect(t, !ok)
	testing.expect_value(t, element, 0)
	_, after_next := rand_next(rng)
	testing.expect_value(t, next.state, after_next.state)
}

@(test)
test_rand_pick_singleton_always_first :: proc(t: ^testing.T) {
	one := []int{77}
	rng := rand_seed(5)
	for i in 0 ..< 8 {
		element, ok, next := rand_pick(one, rng)
		testing.expectf(t, ok && element == 77, "singleton pick[%d] failed", i)
		rng = next
	}
}

@(test)
test_rand_pick_distribution_covers_range :: proc(t: ^testing.T) {
	four := []int{0, 1, 2, 3}
	seen := [4]bool{}
	rng := rand_seed(7)
	for _ in 0 ..< 64 {
		element, ok, next := rand_pick(four, rng)
		testing.expect(t, ok)
		seen[element] = true
		rng = next
	}
	for hit, idx in seen {
		testing.expectf(t, hit, "index %d never picked over 64 draws", idx)
	}
}

RAND_SEED_42_NEXT_FIXED :: i64(803958421)

@(test)
test_rand_next_fixed_golden_and_in_unit_interval :: proc(t: ^testing.T) {
	rng := rand_seed(42)
	got, next := rand_next_fixed(rng)
	testing.expect_value(t, i64(got), RAND_SEED_42_NEXT_FIXED)
	testing.expect(t, i64(got) >= 0 && Fixed(got) < FIXED_ONE)
	_, after_next := rand_next(rng)
	testing.expect_value(t, next.state, after_next.state)
}

@(test)
test_rand_range_golden_and_bounds :: proc(t: ^testing.T) {
	rng := rand_seed(42)
	got, next := rand_range(rng, 0, 100)
	testing.expect_value(t, got, 74)
	testing.expect(t, got >= 0 && got < 100)
	shifted, _ := rand_range(rng, 10, 110)
	testing.expect_value(t, shifted, 84)
	_, after_next := rand_next(rng)
	testing.expect_value(t, next.state, after_next.state)
}

@(test)
test_rand_range_empty_or_inverted_span_yields_lo_and_advances :: proc(t: ^testing.T) {
	rng := rand_seed(42)
	got_empty, next_empty := rand_range(rng, 5, 5)
	testing.expect_value(t, got_empty, 5)
	got_inv, next_inv := rand_range(rng, 9, 2)
	testing.expect_value(t, got_inv, 9)
	_, after_next := rand_next(rng)
	testing.expect_value(t, next_empty.state, after_next.state)
	testing.expect_value(t, next_inv.state, after_next.state)
}

@(test)
test_rand_chance_endpoints_are_total :: proc(t: ^testing.T) {
	rng := rand_seed(42)
	never, next0 := rand_chance(rng, Fixed(0))
	testing.expect(t, !never)
	always, next1 := rand_chance(rng, FIXED_ONE)
	testing.expect(t, always)
	_, after_next := rand_next(rng)
	testing.expect_value(t, next0.state, after_next.state)
	testing.expect_value(t, next1.state, after_next.state)
}

@(test)
test_rand_chance_at_drawn_threshold :: proc(t: ^testing.T) {
	rng := rand_seed(42)
	at_draw, _ := rand_chance(rng, Fixed(RAND_SEED_42_NEXT_FIXED))
	testing.expect(t, !at_draw)
	above, _ := rand_chance(rng, Fixed(RAND_SEED_42_NEXT_FIXED + 1))
	testing.expect(t, above)
}

@(test)
test_rand_split_golden_decorrelated_streams :: proc(t: ^testing.T) {
	rng := rand_seed(42)
	a, b := rand_split(rng)
	testing.expect_value(t, a.state, u64(13679457532755275413))
	testing.expect_value(t, b.state, u64(RAND_SEED_42_NEXT[1]))
	testing.expect(t, a.state != b.state)
	testing.expect(t, a.state != rng.state && b.state != rng.state)
	va, _ := rand_next(a)
	vb, _ := rand_next(b)
	testing.expect(t, va != vb)
}
