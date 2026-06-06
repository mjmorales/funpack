// engine.rand — the seeded integer PRNG kernel (spec §26, §04 §1, §10).
// This is the leaf primitive every random draw in a .fun program threads
// through. It is a STANDALONE kernel: no artifact, interpreter, or tick
// coupling lives here — only the deterministic integer generator and the
// snake-exercised draw surface (seed / next / pick).
//
// DETERMINISM CONTRACT (spec §10, the integer-kernel discipline). Same
// input ⇒ same integer operations ⇒ same bits, on every machine, by
// construction: the generator is splitmix64 computed entirely in u64
// integer arithmetic — no floating-point, no wall-clock, no ambient
// entropy in the path. The Rng state is a fixed-width integer (u64),
// never Fixed and never floating-point, so two Rng values from the same
// seed produce bit-identical draw
// sequences and a different seed diverges. Because the bits are part of
// the determinism warranty, the recorded tick-0 seed reproduces a run
// exactly (spec §25 / §60), the same way the §10.5 transcendental kernels
// are bit-reproducible.
//
// THREADING (spec §04 §1). Rng is THREADED: every draw returns
// (value, next_rng) and is never silently advanced — the caller must
// carry the returned Rng forward. There is no in-place mutation surface;
// a draw consumes an Rng by value and yields the advanced one.
package funpack_runtime

// Rng is the PRNG resource value: a single fixed-width integer state
// (u64). It is a transparent integer, NOT Fixed and NOT floating-point —
// the whole determinism story depends on the state being exact integer
// bits (spec §26: Rng is plain `data`; §10: no floating-point in the path).
Rng :: struct {
	state: u64,
}

// SPLITMIX64 constants — the canonical, well-known generator (the same
// algorithm and constants the Odin stdlib uses to expand a seed). The
// golden constant is the 64-bit fractional part of the golden ratio; the
// two mix multipliers are the published splitmix64 finalizer constants.
// These are part of the bit-identity contract: changing one changes every
// recorded seed's draw sequence (spec §10).
RAND_GOLDEN_GAMMA :: u64(0x9E3779B97F4A7C15)
RAND_MIX_A :: u64(0xBF58476D1CE4E5B9)
RAND_MIX_B :: u64(0x94D049BB133111EB)

// rand_seed builds a deterministic Rng from an integer seed (spec §26
// `Rng.seed`). The Int seed is reinterpreted as the initial u64 state —
// a pure integer cast, no floating-point, no entropy. Same seed ⇒ same
// state ⇒ same draw sequence, always.
rand_seed :: proc(seed: i64) -> Rng {
	return Rng{state = u64(seed)}
}

// rand_next is the splitmix64 step (spec §26 `next`): advance the state
// by the golden gamma, run the published finalizer mix, and return the
// drawn Int alongside the advanced Rng — the (value, next_rng) threading
// contract (spec §04 §1). All-integer ops (add, xor, shift, multiply
// over u64); the u64 → i64 reinterpret at the boundary is exact bits, no
// rounding, no floating-point. Never silently advanced: the next_rng is
// returned, not stored.
rand_next :: proc(rng: Rng) -> (value: i64, next: Rng) {
	advanced := rng.state + RAND_GOLDEN_GAMMA
	z := advanced
	z = (z ~ (z >> 30)) * RAND_MIX_A
	z = (z ~ (z >> 27)) * RAND_MIX_B
	z = z ~ (z >> 31)
	return i64(z), Rng{state = advanced}
}

// rand_bounded reduces a fresh u64 draw to an index in [0, n) using
// Lemire's multiply-shift (spec §26: the reduction must be machine-
// identical and is documented here). It computes (draw * n) >> 64 over a
// u128 intermediate: multiplying the full 64-bit draw by n and taking the
// high 64 bits maps the draw uniformly onto [0, n) with no per-call
// rejection loop, so it is branch-free and bit-identical on every
// machine. Modulo (`draw % n`) would also be deterministic but carries a
// small low-bit bias; multiply-shift biases the high bits negligibly and
// needs no division. n must be > 0 (the caller guarantees a non-empty
// range); n == 0 returns index 0, but pick handles the empty case before
// reaching here.
rand_bounded :: proc(rng: Rng, n: int) -> (index: int, next: Rng) {
	if n <= 0 {
		_, advanced := rand_next(rng)
		return 0, advanced
	}
	draw, advanced := rand_next(rng)
	product := u128(u64(draw)) * u128(u64(n))
	return int(product >> 64), advanced
}

// rand_pick selects a uniform element of a non-empty list, advancing the
// Rng (spec §26 `pick`, snake's `pick(free, rng)`). It is the
// Option-shaped draw: ok is false (the None arm) for an empty list, and
// the Rng still advances so an empty draw is not a silent no-op (spec
// §04 §1 — a draw always consumes the Rng). For a non-empty list it
// reduces the draw with rand_bounded (Lemire multiply-shift) and returns
// the element, ok = true (the Some arm), and the advanced Rng. Parametric
// over $T so the kernel stays decoupled from the interpreter's Value
// union — the interpreter binds T to its element type at the call site.
rand_pick :: proc(list: []$T, rng: Rng) -> (element: T, ok: bool, next: Rng) {
	if len(list) == 0 {
		_, advanced := rand_next(rng)
		return {}, false, advanced
	}
	index, advanced := rand_bounded(rng, len(list))
	return list[index], true, advanced
}
