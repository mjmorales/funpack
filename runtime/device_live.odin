package funpack_runtime

import sdl "vendor:sdl2"

Sdl_Event :: sdl.Event

STICK_AXIS_RANGE :: 32767

when #config(FUNPACK_LIVE, false) {

	Live_Device :: struct {
		window:      ^sdl.Window,
		renderer:    ^sdl.Renderer,
		controllers: [dynamic]^sdl.GameController,
	}

	live_device_open :: proc(
		width: i32,
		height: i32,
		allocator := context.allocator,
	) -> (
		device: Live_Device,
		ok: bool,
	) {
		if sdl.Init(sdl.INIT_VIDEO | sdl.INIT_GAMECONTROLLER) != 0 {
			return {}, false
		}
		window := sdl.CreateWindow(
			"funpack",
			sdl.WINDOWPOS_CENTERED,
			sdl.WINDOWPOS_CENTERED,
			width,
			height,
			sdl.WINDOW_SHOWN,
		)
		if window == nil {
			sdl.Quit()
			return {}, false
		}
		renderer := sdl.CreateRenderer(
			window,
			-1,
			sdl.RENDERER_ACCELERATED | sdl.RENDERER_PRESENTVSYNC,
		)
		if renderer == nil {
			sdl.DestroyWindow(window)
			sdl.Quit()
			return {}, false
		}
		controllers := make([dynamic]^sdl.GameController, allocator)
		for index in 0 ..< sdl.NumJoysticks() {
			if !sdl.IsGameController(index) {
				continue
			}
			handle := sdl.GameControllerOpen(index)
			if handle != nil {
				append(&controllers, handle)
			}
		}
		return Live_Device{window = window, renderer = renderer, controllers = controllers}, true
	}

	live_device_close :: proc(device: Live_Device) {
		dev := device
		for handle in dev.controllers {
			sdl.GameControllerClose(handle)
		}
		delete(dev.controllers)
		if dev.renderer != nil {
			sdl.DestroyRenderer(dev.renderer)
		}
		if dev.window != nil {
			sdl.DestroyWindow(dev.window)
		}
		sdl.Quit()
	}

}

stick_sample_to_fixed :: proc(raw: i16) -> Fixed {
	return fixed_div(to_fixed(i64(raw)), to_fixed(STICK_AXIS_RANGE))
}

key_code_from_scancode :: proc(scancode: sdl.Scancode) -> (code: string, named: bool) {
	#partial switch scancode {
	case .W:
		return "Key::W", true
	case .A:
		return "Key::A", true
	case .S:
		return "Key::S", true
	case .D:
		return "Key::D", true
	case .UP:
		return "Key::Up", true
	case .DOWN:
		return "Key::Down", true
	case .LEFT:
		return "Key::Left", true
	case .RIGHT:
		return "Key::Right", true
	case .SPACE:
		return "Key::Space", true
	case .M:
		return "Key::M", true
	case .RETURN:
		return "Key::Enter", true
	case .F5:
		return "Key::F5", true
	case .F9:
		return "Key::F9", true
	case .B:
		return "Key::B", true
	case .C:
		return "Key::C", true
	case .E:
		return "Key::E", true
	case .F:
		return "Key::F", true
	case .G:
		return "Key::G", true
	case .H:
		return "Key::H", true
	case .I:
		return "Key::I", true
	case .J:
		return "Key::J", true
	case .K:
		return "Key::K", true
	case .L:
		return "Key::L", true
	case .N:
		return "Key::N", true
	case .O:
		return "Key::O", true
	case .P:
		return "Key::P", true
	case .Q:
		return "Key::Q", true
	case .R:
		return "Key::R", true
	case .T:
		return "Key::T", true
	case .U:
		return "Key::U", true
	case .V:
		return "Key::V", true
	case .X:
		return "Key::X", true
	case .Y:
		return "Key::Y", true
	case .Z:
		return "Key::Z", true
	case .ESCAPE:
		return "Key::Escape", true
	case .LSHIFT, .RSHIFT:
		return "Key::Shift", true
	case .TAB:
		return "Key::Tab", true
	}
	return "", false
}

pad_code_from_button :: proc(button: sdl.GameControllerButton) -> (code: string, named: bool) {
	#partial switch button {
	case .A:
		return "PadButton::A", true
	case .B:
		return "PadButton::B", true
	case .X:
		return "PadButton::X", true
	case .Y:
		return "PadButton::Y", true
	case .START:
		return "PadButton::Start", true
	case .BACK:
		return "PadButton::Back", true
	case .LEFTSHOULDER:
		return "PadButton::LeftShoulder", true
	case .RIGHTSHOULDER:
		return "PadButton::RightShoulder", true
	case .DPAD_UP:
		return "PadButton::DpadUp", true
	case .DPAD_DOWN:
		return "PadButton::DpadDown", true
	case .DPAD_LEFT:
		return "PadButton::DpadLeft", true
	case .DPAD_RIGHT:
		return "PadButton::DpadRight", true
	}
	return "", false
}

mouse_code_from_button :: proc(button: u8) -> (code: string, named: bool) {
	switch button {
	case sdl.BUTTON_LEFT:
		return "MouseButton::Left", true
	case sdl.BUTTON_MIDDLE:
		return "MouseButton::Middle", true
	case sdl.BUTTON_RIGHT:
		return "MouseButton::Right", true
	}
	return "", false
}

stick_from_axis :: proc(axis: sdl.GameControllerAxis) -> (code: string, stick_axis: Stick_Axis, named: bool) {
	#partial switch axis {
	case .LEFTX:
		return "Stick::Left", .X, true
	case .LEFTY:
		return "Stick::Left", .Y, true
	case .RIGHTX:
		return "Stick::Right", .X, true
	case .RIGHTY:
		return "Stick::Right", .Y, true
	}
	return "", .X, false
}
