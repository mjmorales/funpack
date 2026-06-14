// The expression-evaluation junction for the §08 View read/reference surface
// (evaluate.odin: eval over View.of / view.ref / view.resolve). A View
// materializes as a List_Value; view.ref(i) mints a Ref carrying its index, and
// view.resolve(ref) reads the referent back to Option::Some in range or
// Option::None out of range (the despawned-referent case). Exercised at the
// resolve junction through run_test_pipeline — the arena gate's
// `switches.resolve(switches.ref(0))` shape, pinned as a deliberate unit beneath
// the golden games.
package funpack

import "core:testing"

@(test)
test_view_ref_resolves_to_some_in_range :: proc(t: ^testing.T) {
	// ref(i) mints a Ref to row i; resolve(ref) reads it back to Option::Some(elem)
	// in range — the arena gate's read over a materialized View (View.of([...])).
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
	// A ref past the View's rows resolves to Option::None (the despawned-referent
	// case the gate behavior's match covers) — a defined None, never a fault.
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
