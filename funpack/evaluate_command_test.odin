// The expression-evaluation junction for the §04/§11/§24 engine command, signal,
// and record CONSTRUCTORS (evaluate.odin: eval_record's engine-record arm, the
// Spawn call wrap). Each constructor materializes as a tagged Record_Value with
// structural equality, so a behavior step's command-list return and a test's
// command equality both evaluate end-to-end. Exercised at the constructor
// junction through run_test_pipeline — the construction-then-equality forms the
// example games reach (yard's persistence commands, arena's Spawn batch), pinned
// as deliberate units beneath the goldens. The value-model equality/display
// rules these rest on are pinned directly in value_test.odin.
package funpack

import "core:testing"

// ── §11 §4 / §24 §1 command & signal record constructors ──────────────────────

@(test)
test_trigger_signal_constructs_and_is_reflexive :: proc(t: ^testing.T) {
	// §11 §4: Trigger{} is a fieldless engine signal record (the Despawn shape), so
	// two of them compare equal and a behavior consuming an inbound [Trigger] is
	// testable against a constructed Trigger.
	source := "import engine.physics.{Trigger}\n" +
		"test \"trigger eq\" {\n" +
		"  assert Trigger{} == Trigger{}\n" +
		"  assert [Trigger{}] == [Trigger{}]\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_persistence_command_records_construct_and_compare :: proc(t: ^testing.T) {
	// §24 persistence commands construct as tagged Record_Values: Save{slot} /
	// Restore{slot} over a String slot, ApplySettings{settings} over the factory
	// Settings — each equal to another built the same way, threading through a list
	// like a command-list return.
	source := "import engine.save.{Save, Restore, ApplySettings, Settings}\n" +
		"test \"persist commands\" {\n" +
		"  assert Save{slot: \"quicksave\"} == Save{slot: \"quicksave\"}\n" +
		"  assert Restore{slot: \"quicksave\"} == Restore{slot: \"quicksave\"}\n" +
		"  assert ApplySettings{settings: Settings.defaults()} == ApplySettings{settings: Settings.defaults()}\n" +
		"  assert [Save{slot: \"quicksave\"}] == [Save{slot: \"quicksave\"}]\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 4)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_command_field_discriminates_under_eq :: proc(t: ^testing.T) {
	// The negative junction: a Save command for a different slot is NOT equal — the
	// field discriminates, proving the records are constructed and compared
	// structurally rather than fail-closing (which would fail the assert).
	source := "import engine.save.{Save}\n" +
		"test \"slot discriminates\" {\n" +
		"  assert (Save{slot: \"a\"} == Save{slot: \"b\"}) == false\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

// ── §04 Spawn command wraps a thing value ─────────────────────────────────────

@(test)
test_spawn_command_wraps_thing_value :: proc(t: ^testing.T) {
	// Spawn(thing) wraps a thing record into a tagged "Spawn" command carrying its
	// one `thing` field, so two Spawns of an equal thing compare equal and a
	// differing thing discriminates — the setup-batch construction the world read
	// folds over.
	source := "import engine.world.{Spawn}\n" +
		"thing Marker { id: Int }\n" +
		"test \"spawn eq\" {\n" +
		"  assert Spawn(Marker{id: 7}) == Spawn(Marker{id: 7})\n" +
		"  assert (Spawn(Marker{id: 1}) == Spawn(Marker{id: 2})) == false\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

// ── §24 §2 nested with-update over engine records ─────────────────────────────

@(test)
test_settings_nested_with_update_and_field_read :: proc(t: ^testing.T) {
	// The yard toggle_motion shape: a nested `with`-update over engine records
	// (Settings.access.reduce_motion flipped via two with-updates) then a nested
	// field read. The Settings.defaults() seed reads reduce_motion false (from the
	// surface schema), the toggle flips it to true.
	source := "import engine.save.{Settings}\n" +
		"test \"toggle access\" {\n" +
		"  let s = Settings.defaults()\n" +
		"  assert s.access.reduce_motion == false\n" +
		"  let access = s.access with { reduce_motion: not s.access.reduce_motion }\n" +
		"  let toggled = s with { access: access }\n" +
		"  assert toggled.access.reduce_motion == true\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}
