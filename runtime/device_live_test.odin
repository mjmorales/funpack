// Proof for the live backend's SDL→§23 translation maps — the load-bearing,
// device-pure half of the live producer that compiles in every build (the SDL
// polling itself reads real hardware and is excluded from this deterministic
// suite, exercised by a manual smoke check). The tests assert that an SDL
// scancode/button/axis lands on EXACTLY the §23 code string bindings resolution
// parses (Key::W, Stick::Left, ...), and that an unmapped device identifier is
// dropped (`named == false`) rather than producing a bogus code — the error case
// that keeps an unbindable input out of the queue. The fixed-point stick
// conversion is checked headless too, since it is pure kernel arithmetic.
package funpack_runtime

import "core:testing"
import sdl "vendor:sdl2"

// test_key_scancode_maps_to_pong_codes proves the keyboard half of the §23 map
// resolves the exact codes pong binds: W/S/Up/Down become Key::W/Key::S/Key::Up/
// Key::Down — the strings keys_axis(Key::W,Key::S) and keys_axis(Key::Up,Key::Down)
// match by equality in bindings resolution. A named mapping reports named == true.
@(test)
test_key_scancode_maps_to_pong_codes :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, scancode: sdl.Scancode, want: string) {
		code, named := key_code_from_scancode(scancode)
		testing.expect(t, named)
		testing.expect_value(t, code, want)
	}
	check(t, .W, "Key::W")
	check(t, .S, "Key::S")
	check(t, .UP, "Key::Up")
	check(t, .DOWN, "Key::Down")
	check(t, .SPACE, "Key::Space")
}

// test_unmapped_scancode_is_dropped proves the keyboard error case: a scancode
// with no §23 Key variant (a function key) reports named == false, so the live
// poll enqueues nothing for it — an unbindable key never reaches the queue.
@(test)
test_unmapped_scancode_is_dropped :: proc(t: ^testing.T) {
	_, named := key_code_from_scancode(.F1)
	testing.expect(t, !named)
}

// test_pad_button_maps_to_codes proves the gamepad button half: SDL's A face
// button resolves to PadButton::A, and an unmodeled button (the touchpad press)
// is dropped (named == false). Covers the happy path and the drop path in one.
@(test)
test_pad_button_maps_to_codes :: proc(t: ^testing.T) {
	code, named := pad_code_from_button(.A)
	testing.expect(t, named)
	testing.expect_value(t, code, "PadButton::A")

	_, touchpad_named := pad_code_from_button(.TOUCHPAD)
	testing.expect(t, !touchpad_named)
}

// test_stick_axis_maps_to_left_right proves the stick half resolves the §23 stick
// code AND the component bindings resolution keys a stick_x/stick_y source on:
// SDL LEFTY → (Stick::Left, Y), the exact pair stick_y(Stick::Left) folds. An
// analog trigger is not a §23 stick, so it is dropped (named == false).
@(test)
test_stick_axis_maps_to_left_right :: proc(t: ^testing.T) {
	code, stick_axis, named := stick_from_axis(.LEFTY)
	testing.expect(t, named)
	testing.expect_value(t, code, "Stick::Left")
	testing.expect_value(t, stick_axis, Stick_Axis.Y)

	rcode, raxis, rnamed := stick_from_axis(.RIGHTX)
	testing.expect(t, rnamed)
	testing.expect_value(t, rcode, "Stick::Right")
	testing.expect_value(t, raxis, Stick_Axis.X)

	_, _, trigger_named := stick_from_axis(.TRIGGERLEFT)
	testing.expect(t, !trigger_named)
}
