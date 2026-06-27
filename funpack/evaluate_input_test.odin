package funpack

import "core:testing"

@(test)
test_input_value_reads_seeded_fixed_channel :: proc(t: ^testing.T) {
	source := "import engine.math.{Fixed}\n" +
		"import engine.input.{Input, PlayerId}\n" +
		"enum Drive: Axis { Strafe, Forward }\n" +
		"test \"analog 1d\" {\n" +
		"  let snap = Input.empty().with_value(PlayerId::P1, Drive::Strafe, 0.0).with_value(PlayerId::P1, Drive::Forward, 1.0)\n" +
		"  assert snap.value(PlayerId::P1, Drive::Forward) == 1.0\n" +
		"  assert snap.value(PlayerId::P1, Drive::Strafe) == 0.0\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_input_value_unseeded_channel_is_zero :: proc(t: ^testing.T) {
	source := "import engine.math.{Fixed}\n" +
		"import engine.input.{Input, PlayerId}\n" +
		"enum Drive: Axis { Strafe }\n" +
		"test \"analog default\" {\n" +
		"  assert Input.empty().value(PlayerId::P1, Drive::Strafe) == 0.0\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_input_axis_reads_seeded_vec2_channel :: proc(t: ^testing.T) {
	source := "import engine.math.{Vec2}\n" +
		"import engine.input.{Input, PlayerId}\n" +
		"enum Drive: Axis { Move }\n" +
		"test \"analog 2d\" {\n" +
		"  let snap = Input.empty().with_axis(PlayerId::P1, Drive::Move, Vec2{x: 1.0, y: 0.0})\n" +
		"  assert snap.axis(PlayerId::P1, Drive::Move) == Vec2{x: 1.0, y: 0.0}\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_input_analog_reseed_reads_last_row :: proc(t: ^testing.T) {
	source := "import engine.math.{Fixed}\n" +
		"import engine.input.{Input, PlayerId}\n" +
		"enum Drive: Axis { Strafe }\n" +
		"test \"analog reseed\" {\n" +
		"  let snap = Input.empty().with_value(PlayerId::P1, Drive::Strafe, 0.5).with_value(PlayerId::P1, Drive::Strafe, 0.25)\n" +
		"  assert snap.value(PlayerId::P1, Drive::Strafe) == 0.25\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 1)
	testing.expect_value(t, report.failed, 0)
}

@(test)
test_input_analog_and_press_stores_are_independent :: proc(t: ^testing.T) {
	source := "import engine.math.{Fixed}\n" +
		"import engine.input.{Input, PlayerId}\n" +
		"enum Drive: Axis { Strafe }\n" +
		"enum Cmd: Button { Jump }\n" +
		"test \"stores independent\" {\n" +
		"  let snap = Input.empty().with_value(PlayerId::P1, Drive::Strafe, 1.0).with_pressed(PlayerId::P1, Cmd::Jump)\n" +
		"  assert snap.pressed(PlayerId::P1, Cmd::Jump) == true\n" +
		"  assert snap.value(PlayerId::P1, Drive::Strafe) == 1.0\n" +
		"}\n"
	report, err := run_test_pipeline(source)
	testing.expect_value(t, err, Pipeline_Error.None)
	testing.expect_value(t, report.passed, 2)
	testing.expect_value(t, report.failed, 0)
}
