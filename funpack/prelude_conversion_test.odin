package funpack

import "core:testing"

@(test)
test_prelude_to_int_resolves_and_truncates :: proc(t: ^testing.T) {
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
