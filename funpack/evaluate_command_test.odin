package funpack

import "core:testing"

@(test)
test_trigger_signal_constructs_and_is_reflexive :: proc(t: ^testing.T) {
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
	source := "import engine.save.{Save}\n" +
		"test \"slot discriminates\" {\n" +
		"  assert (Save{slot: \"a\"} == Save{slot: \"b\"}) == false\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_spawn_command_wraps_thing_value :: proc(t: ^testing.T) {
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

@(test)
test_settings_nested_with_update_and_field_read :: proc(t: ^testing.T) {
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
