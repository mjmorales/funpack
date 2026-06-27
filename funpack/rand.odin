package funpack

// Bit-identical to runtime/rand.odin — the §10 dual-interpreter RNG contract; any change must be mirrored there or gameplay diverges from `funpack test`.
Rng :: struct {
	state: u64,
}

RAND_GOLDEN_GAMMA :: u64(0x9E3779B97F4A7C15)
RAND_MIX_A :: u64(0xBF58476D1CE4E5B9)
RAND_MIX_B :: u64(0x94D049BB133111EB)

rand_seed :: proc(seed: i64) -> Rng {
	return Rng{state = u64(seed)}
}

rand_next :: proc(rng: Rng) -> (value: i64, next: Rng) {
	advanced := rng.state + RAND_GOLDEN_GAMMA
	z := advanced
	z = (z ~ (z >> 30)) * RAND_MIX_A
	z = (z ~ (z >> 27)) * RAND_MIX_B
	z = z ~ (z >> 31)
	return i64(z), Rng{state = advanced}
}

rand_bounded :: proc(rng: Rng, n: int) -> (index: int, next: Rng) {
	if n <= 0 {
		_, advanced := rand_next(rng)
		return 0, advanced
	}
	draw, advanced := rand_next(rng)
	product := u128(u64(draw)) * u128(u64(n))
	return int(product >> 64), advanced
}

rand_next_fixed :: proc(rng: Rng) -> (value: Fixed, next: Rng) {
	draw, advanced := rand_next(rng)
	return Fixed(i64(u64(draw) & 0xFFFF_FFFF)), advanced
}

rand_range :: proc(rng: Rng, lo: i64, hi: i64) -> (value: i64, next: Rng) {
	span := hi - lo
	if span <= 0 {
		_, advanced := rand_next(rng)
		return lo, advanced
	}
	index, advanced := rand_bounded(rng, int(span))
	return lo + i64(index), advanced
}

rand_chance :: proc(rng: Rng, p: Fixed) -> (value: bool, next: Rng) {
	draw, advanced := rand_next_fixed(rng)
	return i64(draw) < i64(p), advanced
}

rand_split :: proc(rng: Rng) -> (a: Rng, b: Rng) {
	seed_a, after_a := rand_next(rng)
	seed_b, _ := rand_next(after_a)
	return Rng{state = u64(seed_a)}, Rng{state = u64(seed_b)}
}
