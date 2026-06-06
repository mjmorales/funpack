// Bit-reproducibility proof for the seeded engine.rand PRNG kernel
// (spec §26, §04 §1, §10). The GOLDEN table below carries the exact
// (seed → exact draw bits) vectors the splitmix64 kernel produces; the
// values are kernel-computed, not hand-transcribed, so asserting them
// proves the generator emits the same integer sequence on every machine.
// A divergence in the generator — a changed constant, floating-point
// slipped into the path, a reordered op — breaks an assertion here, the
// whole point: the table is the determinism tripwire.
//
// The kernel is standalone (no artifact / interpreter / tick coupling),
// so these fixtures call the draw surface directly with hand-built seeds
// and lists, the same pattern fixed_test.odin uses for the scalar kernel.
package funpack_runtime

import "core:testing"

// --- GOLDEN: seed 42 → the first five `next` draws ----------------------
// Each row is the exact Int the kernel returns for the Nth draw in the
// sequence starting from seed 42. These are baked from the kernel's own
// output; re-running the generator must reproduce them bit-for-bit.

RAND_SEED_42_NEXT := [5]i64 {
	-4767286540954276203,
	2949826092126892291,
	5139283748462763858,
	6349198060258255764,
	701532786141963250,
}

@(test)
test_rand_next_golden_sequence :: proc(t: ^testing.T) {
	// Seed a known value, draw a fixed sequence, assert the exact produced
	// integers — same input ⇒ same bits (spec §10).
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
	// Two Rng values from the same seed produce identical draw sequences —
	// the core determinism claim (spec §04 §1, §10). Threaded by value:
	// each draw carries its own next_rng forward, never silently advanced.
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
	// A different seed yields a different draw sequence — the first draw
	// already diverges, so no two distinct runs collide silently.
	v0, _ := rand_next(rand_seed(0))
	v1, _ := rand_next(rand_seed(1))
	v42, _ := rand_next(rand_seed(42))
	testing.expect_value(t, v0, -2152535657050944081)
	testing.expect_value(t, v1, -7995527694508729151)
	testing.expect(t, v0 != v1)
	testing.expect(t, v0 != v42)
	testing.expect(t, v1 != v42)
}

// --- GOLDEN: seed 42 → bounded-index sequence (the pick reduction) ------
// The exact [0, 10) indices Lemire multiply-shift maps the seed-42 draw
// stream onto. pick selects list[index], so these indices ARE the picked
// positions for a 10-element list seeded at 42.

RAND_SEED_42_BOUNDED_10 := [8]int{7, 1, 2, 3, 0, 8, 2, 8}

@(test)
test_rand_bounded_golden_indices :: proc(t: ^testing.T) {
	rng := rand_seed(42)
	for want, i in RAND_SEED_42_BOUNDED_10 {
		got, next := rand_bounded(rng, 10)
		testing.expectf(t, got == want, "bounded idx[%d]: got %d, want %d", i, got, want)
		// Every index must fall in [0, n) — the reduction never escapes range.
		testing.expect(t, got >= 0 && got < 10)
		rng = next
	}
}

@(test)
test_rand_bounded_advances_in_lockstep_with_next :: proc(t: ^testing.T) {
	// bounded draws exactly one value, so its advanced state must equal a
	// plain next from the same Rng — the reduction does not perturb the
	// generator stream, only the returned value.
	rng := rand_seed(999)
	_, after_next := rand_next(rng)
	_, after_bounded := rand_bounded(rng, 6)
	testing.expect_value(t, after_bounded.state, after_next.state)
}

@(test)
test_rand_pick_some_selects_in_range :: proc(t: ^testing.T) {
	// pick over a non-empty list returns the Some arm (ok = true) with an
	// element drawn from the list, and the advanced Rng (spec §26 `pick`,
	// snake's pick(free, rng)). The picked element matches list[index] for
	// the bounded index, so the golden index sequence drives the picks.
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
	// pick over an empty list returns the None arm (ok = false) yet still
	// advances the Rng — a draw is never a silent no-op (spec §04 §1: the
	// Rng is consumed and the next_rng returned even with nothing to pick).
	empty := []int{}
	rng := rand_seed(42)
	element, ok, next := rand_pick(empty, rng)
	testing.expect(t, !ok)
	testing.expect_value(t, element, 0) // zero value of T on the None arm
	_, after_next := rand_next(rng)
	testing.expect_value(t, next.state, after_next.state)
}

@(test)
test_rand_pick_singleton_always_first :: proc(t: ^testing.T) {
	// A one-element list always picks index 0 regardless of the draw — the
	// reduction maps every draw in [0, 1) to 0.
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
	// Over many picks from a 4-element list, every index is reachable — the
	// reduction does not collapse the range to a constant. Deterministic
	// coverage check: the seed-7 stream hits all four indices.
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
