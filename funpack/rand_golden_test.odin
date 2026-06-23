// The expression-evaluation junction for the §26 engine.rand draw surface
// (evaluate.odin: eval_call's seed/next/range/chance/split/pick arms, the §02 §4
// UFCS method→free-call lowering for the self-first draws). Each draw is exercised
// through run_test_pipeline (the lex→…→evaluate driver, the `funpack test` path),
// so the typecheck-admits and evaluator-evaluates halves both prove out.
//
// THE DUAL-INTERPRETER PARITY FLOOR (spec §10, the determinism contract). The
// GOLDEN values pinned here for seed 42 are the SAME bits the runtime kernel
// (runtime/rand_test.odin) and the runtime interpreter (runtime/interp_rng_test.odin)
// pin — funpack/rand.odin and runtime/rand.odin are byte-identical kernel copies, so
// the two interpreters MUST produce the same stream. A draw wired into one evaluator
// but not the other, or a kernel edit mirrored to only one side, moves a value here
// and breaks an assertion — exactly the silent-drop the parity trap warns of.
//
// GOLDEN (seed 42, all derived from the splitmix64 stream RAND_SEED_42_NEXT pins):
//   next()           -> Fixed(803958421)   (the low 32 bits of draw[0] as Q32.32)
//   range(0, 100)    -> 74                  (Lemire over draw[0])
//   range after next -> 15                  (Lemire over draw[1])
//   chance(0.0)      -> false   chance(1.0) -> true   (closed-endpoint total)
package funpack

import "core:testing"

// RAND_HEADER imports the full draw surface: Rng plus the five names the §02 §4
// method forms (rng.next(), rng.range(lo, hi), …) lower into free calls, plus pick.
RAND_HEADER :: "import engine.rand.{Rng, seed, next, range, chance, split, pick}\n"

// rng_helpers threads the Rng through single-draw helper fns — each match is one
// level deep, so the §01 P5 nesting ceiling (3) is never tripped (the deep
// match-in-match form a game would also flatten). first_fixed reads a next()'s
// Fixed, first_range a range()'s Int, range_after_next chains next then range,
// first_chance a chance()'s Bool, split_a/split_b read a split()'s two streams
// back as range draws to compare them.
RAND_HELPERS :: "fn first_fixed(rng: Rng) -> Fixed {\n" +
	"  return match rng.next() { (f, nx) => f }\n" +
	"}\n" +
	"fn first_fixed_in_unit(rng: Rng) -> Bool {\n" +
	"  return match rng.next() { (f, nx) => f >= 0.0 }\n" +
	"}\n" +
	"fn first_fixed_below_one(rng: Rng) -> Bool {\n" +
	"  return match rng.next() { (f, nx) => f < 1.0 }\n" +
	"}\n" +
	"fn first_range(rng: Rng) -> Int {\n" +
	"  return match rng.range(0, 100) { (n, nx) => n }\n" +
	"}\n" +
	"fn range_after_next(rng: Rng) -> Int {\n" +
	"  return match rng.next() { (f, r1) => first_range(r1) }\n" +
	"}\n" +
	"fn first_chance(rng: Rng, p: Fixed) -> Bool {\n" +
	"  return match rng.chance(p) { (b, nx) => b }\n" +
	"}\n" +
	"fn split_first_ranges_differ(rng: Rng) -> Bool {\n" +
	"  return match rng.split() { (ra, rb) => first_range(ra) != first_range(rb) }\n" +
	"}\n"

@(test)
test_rand_draws_pin_seed_42_golden_stream :: proc(t: ^testing.T) {
	// The §26 draws evaluated through the compiler — every value is the seed-42
	// golden the runtime kernel and interpreter also pin (the parity floor).
	source :=
		RAND_HEADER +
		RAND_HELPERS +
		"test \"seed 42 golden stream\" {\n" +
		// next()'s Fixed is the low 32 bits of draw[0] as Q32.32 — a value with no
		// exact short decimal, so it is pinned by the integer draws below (range
		// reduces the SAME draw bit-exactly) and bounded here to [0, 1).
		"  assert first_fixed_in_unit(seed(42)) == true\n" +
		"  assert first_fixed_below_one(seed(42)) == true\n" +
		"  assert first_range(seed(42)) == 74\n" +
		"  assert range_after_next(seed(42)) == 15\n" +
		"  assert first_chance(seed(42), 0.0) == false\n" +
		"  assert first_chance(seed(42), 1.0) == true\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 6)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_rand_draws_are_deterministic_same_seed :: proc(t: ^testing.T) {
	// Same seed ⇒ same stream: two independent draws from seed 42 are equal, the
	// core determinism claim (spec §10). The Rng value itself is comparable, so a
	// re-seeded Rng equals another and a drawn one diverges.
	source :=
		RAND_HEADER +
		RAND_HELPERS +
		"test \"determinism\" {\n" +
		"  assert first_range(seed(42)) == first_range(seed(42))\n" +
		"  assert first_fixed(seed(7)) == first_fixed(seed(7))\n" +
		"  assert seed(42) == seed(42)\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_rand_split_yields_decorrelated_streams :: proc(t: ^testing.T) {
	// split() gives two streams whose first range draws differ — fan-out without
	// correlation (spec §26 split), evaluated through the compiler.
	source :=
		RAND_HEADER +
		RAND_HELPERS +
		"test \"split decorrelates\" {\n" +
		"  assert split_first_ranges_differ(seed(42)) == true\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_rand_draw_mismatch_is_a_counted_failure :: proc(t: ^testing.T) {
	// The negative junction: range(0, 100) from seed 42 is 74, not 0, so the assert
	// FAILS (counted, exit 1) rather than fail-closing — proving the draw is
	// evaluated, not skipped to a compile-class refusal.
	source :=
		RAND_HEADER +
		RAND_HELPERS +
		"test \"wrong draw\" {\n  assert first_range(seed(42)) == 0\n}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 0)
	testing.expect_value(t, report.failed, 1)
	testing.expect_value(t, report.exit_code, 1)
}

@(test)
test_rand_pick_self_first_evaluates :: proc(t: ^testing.T) {
	// rng.pick(items) is the SELF-FIRST draw (snake's rng.pick(free)): the Rng
	// receiver lowers through §02 §4 UFCS into pick(rng, items), boxing the drawn
	// element as Option::Some and threading the advanced Rng. Seed 42 over a
	// 10-element list picks index 7 first (RAND_SEED_42_BOUNDED_10[0]), so the value
	// is the 8th element — the SAME rand_bounded reduction the list-first form drew,
	// proving only the arg order moved, not the drawn value (ADR
	// pick-is-self-first-uniform-rng-surface).
	source :=
		RAND_HEADER +
		"fn picked(rng: Rng) -> Int {\n" +
		"  return match rng.pick([10, 20, 30, 40, 50, 60, 70, 80, 90, 100]) {\n" +
		"    (got, nx) => match got { Option::Some(v) => v, Option::None => -1 }\n" +
		"  }\n" +
		"}\n" +
		"test \"pick self-first\" {\n" +
		"  assert picked(seed(42)) == 80\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}
