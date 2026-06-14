// The expression-evaluation junction for the §23 §5 analog input read surface
// (evaluate.odin/value.odin: Input_Value's two insert-ordered analog stores,
// with_value/value and with_axis/axis). A 1D channel is a (player, axis) → Fixed
// sample; a 2D channel → Vec2. The stores are DETERMINISTIC insert-ordered
// slices (the pressed-set discipline), so value/axis read the LAST matching row
// and an unseeded channel reads the zero default. Exercised at the analog-read
// junction through run_test_pipeline — the krognid read_drive / yard drive
// shapes, pinned as deliberate units beneath the golden games.
package funpack

import "core:testing"

@(test)
test_input_value_reads_seeded_fixed_channel :: proc(t: ^testing.T) {
	// with_value seeds a 1D analog channel; value reads it back as a Fixed — the
	// krognid read_drive shape (two axes seeded and read off one snapshot).
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
	// A value read of a channel no with_value seeded is the zero default — a
	// behavior never faults on a missing analog channel.
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
	// with_axis seeds a 2D analog channel; axis reads it back as a Vec2 — the yard
	// drive shape (the move axis seeded as a Vec2 and read by drive.step).
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
	// A second with_value on the same (player, axis) overwrites the read — the LAST
	// matching row wins (the insert-ordered store's re-seed discipline).
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
	// Seeding an analog channel leaves the button-press set untouched (the three
	// stores are independent slices): a snapshot carrying both reads the held
	// button and the analog sample.
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
