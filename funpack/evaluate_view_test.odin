package funpack

import "core:testing"

@(test)
test_view_ref_resolves_to_some_in_range :: proc(t: ^testing.T) {
	source := "import engine.world.{View}\n" +
		"data Switch { on: Bool }\n" +
		"test \"view resolve some\" {\n" +
		"  let switches = View.of([Switch{on: true}, Switch{on: false}])\n" +
		"  assert switches.resolve(switches.ref(0)) == Option::Some(Switch{on: true})\n" +
		"  assert switches.resolve(switches.ref(1)) == Option::Some(Switch{on: false})\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_view_resolve_out_of_range_is_none :: proc(t: ^testing.T) {
	source := "import engine.world.{View}\n" +
		"data Switch { on: Bool }\n" +
		"test \"view resolve none\" {\n" +
		"  let switches = View.of([Switch{on: true}])\n" +
		"  assert switches.resolve(switches.ref(5)) == Option::None\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_view_count_and_at_evaluate_over_a_fixture :: proc(t: ^testing.T) {
	source := "import engine.world.{View}\n" +
		"data Switch { on: Bool }\n" +
		"test \"view count and at\" {\n" +
		"  let switches = View.of([Switch{on: true}, Switch{on: false}, Switch{on: true}])\n" +
		"  assert switches.count() == 3\n" +
		"  assert switches.at(0) == Switch{on: true}\n" +
		"  assert switches.at(2) == Switch{on: true}\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 3)
	testing.expect_value(t, report.failed, 0)
}
