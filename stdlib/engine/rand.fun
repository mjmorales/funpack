@doc("Seeded, threaded randomness — the only source of nondeterminism, and it is explicit. There is no ambient/global RNG. Every draw returns the next Rng alongside its value, so the seed is threaded through the sim and replays are bit-identical. Rng is serializable data, so it lives in a blackboard.")

import engine.prelude.{Int, Bool, Fixed, Option}

@doc("A deterministic RNG state. Same seed + same draws => same stream on every machine.")
data Rng { state: Int }

@doc("An RNG from an integer seed.")
extern fn seed(n: Int) -> Rng

@doc("A uniform Fixed in [0, 1) and the advanced RNG.")
extern fn next(self: Rng) -> (Fixed, Rng)
@doc("A uniform Int in [lo, hi) and the advanced RNG.")
extern fn range(self: Rng, lo: Int, hi: Int) -> (Int, Rng)
@doc("A uniformly chosen element (None if the list is empty) and the advanced RNG.")
extern fn pick(self: Rng, items: [T]) -> (Option[T], Rng)
@doc("True with the given probability in [0, 1], and the advanced RNG.")
extern fn chance(self: Rng, p: Fixed) -> (Bool, Rng)
@doc("Two independent RNG streams from one, for fan-out without correlation.")
extern fn split(self: Rng) -> (Rng, Rng)
