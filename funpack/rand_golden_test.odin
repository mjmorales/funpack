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

// ── let (v, next) tuple-destructure: the threaded-Rng consume idiom ──────────────
//
// The friction the §02 §5/§8 `let (a, b) = expr` ruling closes (ADR
// 2026-06-24-let-tuple-destructure-binding): before it, the ONLY tuple-destructure
// was a `match` arm, so sequential Rng threading nested one match per draw and a
// multi-draw generator tripped the §01 P5 nesting ceiling (3). The RAND_HELPERS
// above show exactly that workaround — every helper threads through a one-deep
// `match`. These tests pin the consume side: `let (v, next) = draw(rng)` compiles,
// runs deterministically, and threads SEQUENTIALLY with no nesting, so a chain of
// draws that would have nested past the ceiling is now flat.

// let_two_draws threads two range draws via `let (..)` and returns their sum — the
// canonical sequential-threading shape the engine-api/game-model skills lead with.
// The same two draws as a `match` chain would nest two deep; as `let`s they are
// flat, so an N-draw generator no longer trips the nesting ceiling.
RAND_LET_HELPERS :: "fn let_first_range(rng: Rng) -> Int {\n" +
	"  let (n, nx) = rng.range(0, 100)\n" +
	"  return n\n" +
	"}\n" +
	"fn let_range_after_next(rng: Rng) -> Int {\n" +
	"  let (f, r1) = rng.next()\n" +
	"  let (n, r2) = r1.range(0, 100)\n" +
	"  return n\n" +
	"}\n"

@(test)
test_let_tuple_destructure_threads_rng_deterministically :: proc(t: ^testing.T) {
	// The `let (v, next) = draw(rng)` consume idiom evaluates to the SAME seed-42
	// golden the one-deep `match` form pins (first_range == 74, next-then-range ==
	// 15), proving the destructure binds the value AND threads the advanced Rng
	// position-for-position with the match form — and the sequential `let` chain
	// never nests, so the nesting ceiling that the match form skirts is moot here.
	source :=
		RAND_HEADER +
		RAND_HELPERS +
		RAND_LET_HELPERS +
		"test \"let-threaded draws match the match-threaded goldens\" {\n" +
		"  assert let_first_range(seed(42)) == 74\n" +
		"  assert let_range_after_next(seed(42)) == 15\n" +
		"  assert let_first_range(seed(42)) == first_range(seed(42))\n" +
		"  assert let_range_after_next(seed(42)) == range_after_next(seed(42))\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 4)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_let_tuple_destructure_in_test_body :: proc(t: ^testing.T) {
	// The destructure also binds directly in a `test` body (the check_tests +
	// test-eval loop path, distinct from a fn body's check_statements): a `let (v,
	// next)` over a draw binds both, and a follow-on draw threads `next` — the
	// asserts read the bound value. This is the in-test consume form an author writes
	// when probing a draw.
	source :=
		RAND_HEADER +
		"test \"destructure in test body\" {\n" +
		"  let (n, nx) = seed(42).range(0, 100)\n" +
		"  let (n2, nx2) = nx.range(0, 100)\n" +
		"  assert n == 74\n" +
		"  assert n2 >= 0\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_let_tuple_destructure_arity_mismatch_is_compile_error :: proc(t: ^testing.T) {
	// A binder count that disagrees with the RHS tuple arity cannot zip — a
	// `(value, next)` 2-tuple bound to three names — so it is the compile-class
	// Type_Error.Let_Tuple_Arity_Mismatch (Typecheck_Failed, exit 2), NOT a counted
	// assert failure. The diagnostic names the destructure, steering the fix.
	source :=
		RAND_HEADER +
		"fn bad(rng: Rng) -> Int {\n" +
		"  let (a, b, c) = rng.range(0, 100)\n" +
		"  return a\n" +
		"}\n" +
		"test \"arity\" {\n  assert bad(seed(42)) == 0\n}\n"
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
}

@(test)
test_let_tuple_destructure_non_tuple_rhs_is_compile_error :: proc(t: ^testing.T) {
	// Destructuring a non-tuple RHS (a bare Int) has no positions to bind, so it is
	// the same Let_Tuple_Arity_Mismatch compile-class refusal rather than a silent
	// nil-bound name — the destructure form demands a tuple RHS (spec §02 §5/§8).
	source :=
		RAND_HEADER +
		"fn bad(rng: Rng) -> Int {\n" +
		"  let (a, b) = 5\n" +
		"  return a\n" +
		"}\n" +
		"test \"non-tuple\" {\n  assert bad(seed(42)) == 0\n}\n"
	_, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.Typecheck_Failed)
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
