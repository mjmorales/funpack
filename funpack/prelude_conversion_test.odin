// The engine.prelude conversion + Option-predicate surface the auto-prelude
// exposes by bare name. to_int (Fixed -> Int, to_fixed's inverse) and is_some
// (Option[T] -> Bool, or_else's predicate complement) are declared in
// stdlib/engine/prelude.fun and must resolve in user code exactly like their
// siblings to_fixed and or_else — no explicit import, the prelude is auto-in-scope.
// The drift this guards: a member declared in prelude.fun yet absent from the
// compiler surface (surface.odin STDLIB_SURFACE) is Unresolved_Name on a bare
// call even though its sibling to_fixed resolves — a declared-vs-enforced surface
// drift no version check catches. This fixture pins both through
// the full single-source pipeline (resolve -> typecheck -> eval) to their exact
// values, so a future surface prune cannot silently re-open the gap.
package funpack

import "core:testing"

@(test)
test_prelude_to_int_resolves_and_truncates :: proc(t: ^testing.T) {
	// to_int(Fixed) -> Int is the integer part truncated toward zero — the to_fixed
	// inverse. A bare call resolves through the auto-prelude and folds to its exact Int.
	src := `fn ipart(x: Fixed) -> Int { return to_int(x) }

test "to_int truncates toward zero" {
  assert ipart(3.75) == 3
  assert ipart(0.0) == 0
}`
	report, err := run_test_pipeline(src)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_prelude_is_some_resolves_and_reports_presence :: proc(t: ^testing.T) {
	// is_some(Option[T]) -> Bool is the Option presence predicate. A bare call
	// resolves through the auto-prelude and folds to the Option's presence bit.
	src := `import engine.list.{first}

fn present(o: Option[Int]) -> Bool { return is_some(o) }

test "is_some reports Option presence" {
  assert present(first([7])) == true
  assert present(first([])) == false
}`
	report, err := run_test_pipeline(src)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}
