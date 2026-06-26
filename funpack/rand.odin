// engine.rand — the seeded integer PRNG kernel (spec §26, §04 §1, §10).
// This is the leaf primitive every random draw in a .fun program threads
// through. It is a STANDALONE kernel: no AST, evaluator, or surface
// coupling lives here — only the deterministic integer generator and the
// threaded draw surface (seed / next / range / chance / split / pick).
//
// DETERMINISM CONTRACT (spec §10, the integer-kernel discipline). Same
// input ⇒ same integer operations ⇒ same bits, on every machine, by
// construction: the generator is splitmix64 computed entirely in u64
// integer arithmetic — no floating-point, no wall-clock, no ambient
// entropy in the path. The Rng state is a fixed-width integer (u64),
// never Fixed and never floating-point, so two Rng values from the same
// seed produce bit-identical draw sequences and a different seed diverges.
//
// PROVENANCE — this is the CANONICAL kernel; runtime/rand.odin is its
// DELIBERATE COPY, NOT a shared import (the same kernel-copy-not-link obligation
// funpack/trig.odin carries against runtime/trig.odin, and in the same canonical
// direction: funpack is the original, runtime mirrors it). funpack/** (the
// compiler, which evaluates draws for `funpack test`) and runtime/** (gameplay
// execution) are separate products (spec §29, §09); the artifact file is the only
// sanctioned coupling, so neither links the other's internals. The two kernels
// carry a bit-identity OBLIGATION to each other — the same draw sequence for every
// seed — the dual-interpreter parity bet (a surface wired into only one evaluator
// silently drops the step in the other). Any change to a mirrored proc here must be
// mirrored byte-for-byte in runtime/rand.odin (and the golden stream re-asserted in
// both) or the products diverge. The runtime copy's only deltas are its package
// line, its provenance note, the Fixed-type home, and a runtime-LOCAL generic
// rand_pick (the compiler evaluates pick through eval_rand_pick instead, so the
// generic is outside the mirrored obligation).
//
// THREADING (spec §04 §1). Rng is THREADED: every draw returns
// (value, next_rng) and is never silently advanced — the caller must
// carry the returned Rng forward. A draw consumes an Rng by value and
// yields the advanced one.
package funpack

// Rng is the PRNG resource value: a single fixed-width integer state
// (u64). It is a transparent integer, NOT Fixed and NOT floating-point —
// the whole determinism story depends on the state being exact integer
// bits (spec §26: Rng is plain `data`; §10: no floating-point in the path).
Rng :: struct {
	state: u64,
}

// SPLITMIX64 constants — the canonical, well-known generator. The golden
// constant is the 64-bit fractional part of the golden ratio; the two mix
// multipliers are the published splitmix64 finalizer constants. These are
// part of the bit-identity contract with runtime/rand.odin: changing one
// changes every recorded seed's draw sequence (spec §10).
RAND_GOLDEN_GAMMA :: u64(0x9E3779B97F4A7C15)
RAND_MIX_A :: u64(0xBF58476D1CE4E5B9)
RAND_MIX_B :: u64(0x94D049BB133111EB)

// rand_seed builds a deterministic Rng from an integer seed (spec §26
// `seed`). The Int seed is reinterpreted as the initial u64 state — a pure
// integer cast, no floating-point, no entropy. Same seed ⇒ same state ⇒
// same draw sequence, always.
rand_seed :: proc(seed: i64) -> Rng {
	return Rng{state = u64(seed)}
}

// rand_next is the splitmix64 step (spec §26 `next` base): advance the
// state by the golden gamma, run the published finalizer mix, and return
// the drawn Int alongside the advanced Rng — the (value, next_rng)
// threading contract (spec §04 §1). All-integer ops (add, xor, shift,
// multiply over u64); the u64 → i64 reinterpret at the boundary is exact
// bits, no rounding, no floating-point. Never silently advanced: the
// next_rng is returned, not stored.
rand_next :: proc(rng: Rng) -> (value: i64, next: Rng) {
	advanced := rng.state + RAND_GOLDEN_GAMMA
	z := advanced
	z = (z ~ (z >> 30)) * RAND_MIX_A
	z = (z ~ (z >> 27)) * RAND_MIX_B
	z = z ~ (z >> 31)
	return i64(z), Rng{state = advanced}
}

// rand_bounded reduces a fresh u64 draw to an index in [0, n) using
// Lemire's multiply-shift (spec §26). It computes (draw * n) >> 64 over a
// u128 intermediate: multiplying the full 64-bit draw by n and taking the
// high 64 bits maps the draw uniformly onto [0, n) with no per-call
// rejection loop, so it is branch-free and bit-identical on every machine.
// n must be > 0 (the caller guarantees a non-empty range); n == 0 returns
// index 0, but the callers handle the empty case before reaching here.
rand_bounded :: proc(rng: Rng, n: int) -> (index: int, next: Rng) {
	if n <= 0 {
		_, advanced := rand_next(rng)
		return 0, advanced
	}
	draw, advanced := rand_next(rng)
	product := u128(u64(draw)) * u128(u64(n))
	return int(product >> 64), advanced
}

// rand_next_fixed draws a uniform Fixed in [0, 1) and returns it with the
// advanced Rng (spec §26 `next`). Determinism: the low 32 bits of a fresh
// splitmix64 draw are reinterpreted as the FRACTIONAL part of a Q32.32 Fixed
// (FIXED_FRACTION_BITS == 32) — an integer mask, no floating-point. The
// integer part is 0, so the value lies in [0, 1): the smallest draw is 0.0
// (all fraction bits zero) and the largest is (2^32 - 1)/2^32, strictly
// below 1.0. Using the low 32 bits keeps this draw orthogonal to
// rand_bounded's high-bit Lemire reduction, and is the SAME masking
// runtime/rand.odin uses (the §10 dual-interpreter determinism contract).
rand_next_fixed :: proc(rng: Rng) -> (value: Fixed, next: Rng) {
	draw, advanced := rand_next(rng)
	return Fixed(i64(u64(draw) & 0xFFFF_FFFF)), advanced
}

// rand_range draws a uniform Int in [lo, hi) and returns it with the
// advanced Rng (spec §26 `range`). It reduces a fresh draw with rand_bounded
// (Lemire multiply-shift) over the half-open span (hi - lo), then offsets by
// lo, so the distribution and the bit-identity match pick's index reduction
// exactly. An empty or inverted span (hi <= lo) yields lo and still advances
// the Rng — the §04 §1 no-silent-advance contract, never a fault.
rand_range :: proc(rng: Rng, lo: i64, hi: i64) -> (value: i64, next: Rng) {
	span := hi - lo
	if span <= 0 {
		_, advanced := rand_next(rng)
		return lo, advanced
	}
	index, advanced := rand_bounded(rng, int(span))
	return lo + i64(index), advanced
}

// rand_chance draws a Bool that is true with probability p (a Fixed in
// [0, 1]) and returns it with the advanced Rng (spec §26 `chance`). It draws
// the SAME uniform Fixed in [0, 1) rand_next_fixed produces and returns
// `draw < p`, so a p of 0.0 is always false (no draw is < 0.0) and a p of
// 1.0 is always true (every draw in [0, 1) is < 1.0). The comparison is
// exact Q32.32 integer ordering — no floating-point — bit-identical to
// runtime/rand.odin.
rand_chance :: proc(rng: Rng, p: Fixed) -> (value: bool, next: Rng) {
	draw, advanced := rand_next_fixed(rng)
	return i64(draw) < i64(p), advanced
}

// rand_split derives two independent RNG streams from one and returns them
// (spec §26 `split`), for fan-out without correlation. It takes two
// successive splitmix64 draws off the input Rng: the first seeds stream A,
// the second seeds stream B. Because each seed is a finalized splitmix64
// output (the full avalanche mix), the two streams decorrelate — neither is
// a prefix of the other and both differ from the parent's own continuation.
// Pure integer ops, bit-identical to runtime/rand.odin.
rand_split :: proc(rng: Rng) -> (a: Rng, b: Rng) {
	seed_a, after_a := rand_next(rng)
	seed_b, _ := rand_next(after_a)
	return Rng{state = u64(seed_a)}, Rng{state = u64(seed_b)}
}
