// The LIVE device boundary: polls real keyboard + gamepad through vendor:sdl2
// and feeds the SAME injected raw-event queue the headless producer drains
// (bindings_resolve.odin's Device_Queue). It is an interchangeable producer of
// the §23 §5 vocabulary — the deterministic contract is the resolved snapshot,
// not the device, so a live session enqueues exactly the raw events a headless
// one would and replays bit-identically (§23 §4, §09 §6).
//
// ODIN-FIRST (verified): vendor:sdl2 covers all three surfaces this layer needs
// — keyboard (sdl_keyboard/sdl_scancode + KEYDOWN/KEYUP events), gamepad buttons
// (sdl_gamecontroller + CONTROLLERBUTTONDOWN/UP), and stick axes (the game
// controller axis API + CONTROLLERAXISMOTION) — so no custom device path is
// written; this layer is a thin SDL→§23 translation over the existing queue.
//
// IMPURE BY DESIGN: this is the ONLY runtime code that reads the real clock and
// real devices. Nothing it produces reaches sim state except through the
// already-resolved snapshot — it adds raw events to the queue, bindings
// resolution folds them, and the resolved Input is the sole nondeterminism
// record. It adds NO resolution logic and NO new snapshot type, and it does NOT
// touch the snapshot, bindings resolution, or recording (those are
// device-agnostic and resolved elsewhere).
//
// HEADLESS/LIVE SEPARATION: the SDL import is held only by a type alias so
// -vet -strict-style accepts it, while every SDL CALL lives behind
// `when #config(FUNPACK_LIVE, false)`. A default (headless/test/CI) build
// references no SDL symbol and links nothing; the live polling compiles only
// under `-define:FUNPACK_LIVE=true`, the build-tag/when-clause separation the
// Odin build model allows for a single-package file (an import cannot itself sit
// inside a `when`). The deterministic suite never compiles the live calls, so it
// is unaffected by this file's presence (§23 §5 producer interchangeability).
package funpack_runtime

import sdl "vendor:sdl2"

// Sdl_Event keeps the vendor:sdl2 import live for -vet under a headless build
// (where every SDL call below is compiled out) WITHOUT emitting a single SDL
// symbol — a type alias is dead-stripped, so the headless binary links no SDL.
// The live path uses this same alias as its event buffer type.
Sdl_Event :: sdl.Event

// STICK_AXIS_RANGE is SDL's full-scale stick magnitude (SDL reports an axis as
// an i16 in [-32768, 32767]); the live sampler divides a raw reading by this on
// the fixed-point kernel to land it in [-1, 1] with no float in the path, so the
// resolver's engine deadzone and clamp see a Fixed exactly like an injected one
// (§23 §4). The negative extreme (-32768) maps slightly past -1 and the
// resolver's clamp pins it, matching the headless contract.
STICK_AXIS_RANGE :: 32767

when #config(FUNPACK_LIVE, false) {

	// Live_Device is the open SDL resource set the live producer holds for the
	// session: the visible window the OS routes keyboard focus to, the renderer
	// the session loop presents the frame through, and the game controllers opened
	// at startup. The keyboard needs no handle — SDL delivers key events through
	// the event queue once the window holds focus. The renderer is created here so
	// its lifetime is bound to the open/close pair; this layer creates and destroys
	// it but never draws or presents — drawing and presenting belong to the session
	// loop, not this layer.
	Live_Device :: struct {
		window:      ^sdl.Window,
		renderer:    ^sdl.Renderer,
		controllers: [dynamic]^sdl.GameController,
	}

	// live_device_open initializes SDL's events + game controller subsystems,
	// creates a visible width×height window so the OS delivers keyboard events and
	// the session is on screen, creates the renderer the present boundary draws
	// through, and opens every connected game controller. `ok` is false when SDL
	// init, the window, or the renderer fails — each failure unwinds the resources
	// already opened (reverse order) before returning, so a caller on a machine
	// without a display or GPU fails closed rather than polling a half-initialized
	// SDL. This is impure (touches the real device stack) and runs once before the
	// tick loop, never per tick.
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

	// live_device_close releases every SDL resource the live producer opened —
	// the controllers, then the renderer, then the window, then SDL itself — in
	// reverse open order. Called once after the tick loop; the dynamic controller
	// buffer is freed alongside.
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

	// poll_live_window drains every SDL event waiting since the previous tick and
	// translates each into a raw §23 device event enqueued onto the SAME headless
	// queue bindings resolution drains. It adds NO coalescing or resolution — the
	// queue's seq stamping preserves SDL's delivery order, and resolve_tick folds
	// the window exactly as it does for an injected producer. An event whose
	// device code has no §23 name (an unmapped key, an unmodeled pad button) is
	// dropped here, so only the bindable vocabulary reaches the queue.
	poll_live_window :: proc(queue: ^Device_Queue) {
		event: Sdl_Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .KEYDOWN:
				// SDL repeats a held key; only the first down is the §23 edge, so
				// a repeat is ignored — the level is already set from the first.
				if event.key.repeat == 0 {
					if code, named := key_code_from_scancode(event.key.keysym.scancode); named {
						enqueue_key_down(queue, code)
					}
				}
			case .KEYUP:
				if code, named := key_code_from_scancode(event.key.keysym.scancode); named {
					enqueue_key_up(queue, code)
				}
			case .CONTROLLERBUTTONDOWN:
				if code, named := pad_code_from_button(sdl.GameControllerButton(event.cbutton.button)); named {
					enqueue_pad_down(queue, code)
				}
			case .CONTROLLERBUTTONUP:
				if code, named := pad_code_from_button(sdl.GameControllerButton(event.cbutton.button)); named {
					enqueue_pad_up(queue, code)
				}
			case .CONTROLLERAXISMOTION:
				stick, stick_axis, named := stick_from_axis(sdl.GameControllerAxis(event.caxis.axis))
				if named {
					enqueue_stick_sample(queue, stick, stick_axis, stick_sample_to_fixed(event.caxis.value))
				}
			}
		}
	}
}

// stick_sample_to_fixed converts a raw i16 axis reading to a fixed-point
// value in units of the full-scale range — divide with i64 arithmetic lifted
// through to_fixed, so NO float ever enters (§23 §4). It references no SDL
// symbol, so it compiles in every build and the headless suite pins its rails:
// the i16 range is asymmetric, so -32768 lands just past -1 and the resolver's
// downstream clamp pins it to exactly -1 (the deadzone/clamp is the resolver's,
// not this conversion's). +32767 is exactly 1.0.
stick_sample_to_fixed :: proc(raw: i16) -> Fixed {
	return fixed_div(to_fixed(i64(raw)), to_fixed(STICK_AXIS_RANGE))
}

// --- SDL → §23 name maps (compiled in every build) -----------------------
// These translate an SDL device identifier onto the §23 enum-variant string the
// bindings table parses (Key::W, Stick::Left, PadButton::A). They reference only
// vendor:sdl2 ENUM VALUES, never an SDL call, so they hold no link dependency and
// compile in headless builds too — keeping the SDL→§23 vocabulary in one place
// the live poll above reads.

// key_code_from_scancode maps an SDL physical scancode onto the §23 "Key::<Name>"
// token the bindings table matches by equality. `named` is false for a scancode
// with no §23 Key variant, so an unbindable key is dropped before it reaches the
// queue. The covered set is the §23 Key vocabulary the golden examples bind —
// pong/snake/hunt's movement keys + space, and yard's menu keys (F5/F9/M/Enter
// for Save/Restore/ToggleMotion/Apply); a scancode outside it is simply not a
// §23 key.
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
	}
	return "", false
}

// pad_code_from_button maps an SDL game-controller button onto the §23
// "PadButton::<Name>" token. `named` is false for a button with no §23 variant,
// dropping it before the queue. The names mirror SDL's standard face/shoulder/
// dpad layout so a binding written against PadButton::A resolves the A face button.
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

// stick_from_axis maps an SDL game-controller axis onto its §23 stick code and
// the Stick_Axis component the queue's stick sample carries. SDL's LEFTX/LEFTY
// resolve to "Stick::Left" X/Y and RIGHTX/RIGHTY to "Stick::Right" X/Y — the same
// (code, axis) pair bindings resolution keys a stick_x/stick_y source on. The
// analog triggers (TRIGGERLEFT/RIGHT) are not §23 sticks, so `named` is false and
// they are dropped before the queue.
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
