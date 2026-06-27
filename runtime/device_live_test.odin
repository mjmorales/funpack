package funpack_runtime

import "core:testing"
import sdl "vendor:sdl2"

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

@(test)
test_key_scancode_maps_to_yard_menu_codes :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, scancode: sdl.Scancode, want: string) {
		code, named := key_code_from_scancode(scancode)
		testing.expect(t, named)
		testing.expect_value(t, code, want)
	}
	check(t, .F5, "Key::F5")
	check(t, .F9, "Key::F9")
	check(t, .M, "Key::M")
	check(t, .RETURN, "Key::Enter")
}

@(test)
test_key_scancode_maps_full_alphabet_and_modifiers :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, scancode: sdl.Scancode, want: string) {
		code, named := key_code_from_scancode(scancode)
		testing.expect(t, named)
		testing.expect_value(t, code, want)
	}
	check(t, .B, "Key::B")
	check(t, .E, "Key::E")
	check(t, .Q, "Key::Q")
	check(t, .Z, "Key::Z")
	check(t, .ESCAPE, "Key::Escape")
	check(t, .TAB, "Key::Tab")
	check(t, .LSHIFT, "Key::Shift")
	check(t, .RSHIFT, "Key::Shift")
}

@(test)
test_unmapped_scancode_is_dropped :: proc(t: ^testing.T) {
	_, named := key_code_from_scancode(.F1)
	testing.expect(t, !named)
}

@(test)
test_pad_button_maps_to_codes :: proc(t: ^testing.T) {
	code, named := pad_code_from_button(.A)
	testing.expect(t, named)
	testing.expect_value(t, code, "PadButton::A")

	_, touchpad_named := pad_code_from_button(.TOUCHPAD)
	testing.expect(t, !touchpad_named)
}

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

@(test)
test_stick_sample_to_fixed_rails :: proc(t: ^testing.T) {
	testing.expect_value(t, stick_sample_to_fixed(0), Fixed(0))
	testing.expect_value(t, stick_sample_to_fixed(32767), to_fixed(1))
	past_neg_one := stick_sample_to_fixed(-32768)
	testing.expect_value(t, past_neg_one, Fixed(-4295098372))
	testing.expect_value(t, fixed_clamp(past_neg_one, fixed_neg(to_fixed(1)), to_fixed(1)), fixed_neg(to_fixed(1)))
	testing.expect_value(t, stick_sample_to_fixed(-16384) < 0, true)
}
