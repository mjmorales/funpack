// Headless proof for the §28.3 offscreen screenshot capture (session_capture_frame).
//
// The capture is the IMPURE present-boundary twin of draw_list: it paints a §20
// draw-list through an offscreen software renderer and reads the RGBA8 pixels back.
// The whole path is CPU — a CreateRGBSurfaceWithFormat target, a
// CreateSoftwareRenderer over it, a RenderReadPixels off it — so it needs no display
// once the SDL video subsystem is up. The capture-only Init forces SDL's "dummy" video
// driver: on a no-display host (CI, a headless attach session, macOS with no window
// server) SDL_Init(SDL_INIT_VIDEO) against the default driver FAILS, but the dummy
// driver brings the subsystem up with no display, so the CPU render path runs
// identically on dev (macOS, no separate display) and CI.
//
// This whole file is when #config(FUNPACK_LIVE)-gated — it compiles ONLY under
// -define:FUNPACK_LIVE=true (the same gate as the code it exercises), so the default
// define-free `task test` suite stays SDL-free, codec-free, and deterministic. Run it
// with `task runtime:test-live` (odin test . -define:FUNPACK_LIVE=true), which links
// vendor:sdl2's native lib. Its passing on a plain dev host with no display set up is
// the headless proof the s-offscreen / t-headless-session story demands.
//
// The capture is non-deterministic/visual (§20 §5): it is never on the determinism
// path, reads the committed program, and writes nothing back (the observe warranty).
// This test asserts the capability, not a pixel-exact golden — a frozen pixel golden
// would couple visual output into the suite, which §20 §5 forbids.
package funpack_runtime

// @(require): the whole body is when #config(FUNPACK_LIVE)-gated, so in the default
// define-free build these three imports are referenced nowhere — @(require) keeps them
// from tripping -vet's unused-import check there (the device_live.odin convention,
// expressed for test imports). Under -define:FUNPACK_LIVE the gated test uses all three.
@(require) import "core:encoding/base64"
@(require) import "core:image/qoi"
@(require) import "core:testing"

when #config(FUNPACK_LIVE, false) {

	// capture_probe_program is the minimal artifact the capture needs: only the
	// entrypoint's logical draw extent is read (160x120 → a 4x integer scale → a
	// 640x480 window, the same per-artifact geometry the live window derives). Every
	// other Program field is the empty set — an asset-less program decodes to an empty
	// §19 atlas, so the offscreen renderer's texture cache is empty and the paint is the
	// bare draw-list with no atlas upload.
	@(private = "file")
	capture_probe_program :: proc() -> Program {
		program: Program
		program.entrypoint.logical_w = 160
		program.entrypoint.logical_h = 120
		return program
	}

	// test_headless_capture_decodes_to_a_frame is the headless capability proof: drive
	// session_capture_frame with the probe program and a single white Draw_Rect, then
	// assert the §28.3 contract end-to-end on a no-display host —
	//   1. ok == true            (the dummy-driver Init succeeded; the capture did NOT
	//                             fall to its no-display boundary refusal)
	//   2. width>0 && height>0   (the captured extent is the derived 640x480 window)
	//   3. the payload is a DECODABLE frame — base64 → QOI → RGBA back, with the decoded
	//      image carrying the same dimensions and 4 channels (the readback shape).
	// (3) is what makes this a proof rather than a type-check: the bytes round-trip
	// through the real codec to a real image, so the offscreen software render + readback
	// + encode actually produced a valid frame headless.
	@(test)
	test_headless_capture_decodes_to_a_frame :: proc(t: ^testing.T) {
		program := capture_probe_program()

		// A single white rect across the board's first cell — a real paint through the
		// present pass, not an empty list, so the readback carries drawn pixels.
		rect := Draw_Rect {
			at    = Vec2{to_fixed(8), to_fixed(8)},
			size  = Vec2{to_fixed(16), to_fixed(16)},
			color = .White,
		}
		draw := Draw_List {
			cmds = []Draw_Cmd{rect},
		}

		encoded, width, height, ok := session_capture_frame(&program, draw, context.temp_allocator)

		// The headless capability: the dummy-driver Init brought SDL video up with no
		// display, so the capture succeeded instead of refusing.
		testing.expect(t, ok, "headless capture must succeed via the dummy video driver — no display required")
		if !ok {
			return
		}
		testing.expect(t, width > 0 && height > 0, "captured frame must report a positive extent")
		// 160x120 logical → 4x integer scale → 640x480 window (live_window_for).
		testing.expect_value(t, width, 640)
		testing.expect_value(t, height, 480)

		// Round-trip the payload back to a real image: base64 → QOI → RGBA. A decode that
		// yields an image of the captured dimensions and 4 channels proves the encoded
		// bytes are a genuine frame, not an empty or malformed buffer. The decode runs on
		// context.allocator (NOT temp) so qoi.destroy's bare free() frees from the same
		// arena it allocated — passing temp here would make destroy a cross-allocator free.
		qoi_bytes := base64.decode(encoded, base64.DEC_TABLE, context.temp_allocator)
		testing.expect(t, len(qoi_bytes) > 0, "base64 payload must decode to non-empty QOI bytes")

		img, decode_err := qoi.load_from_bytes(qoi_bytes, qoi.Options{}, context.allocator)
		testing.expect(t, decode_err == nil, "the captured payload must decode as QOI")
		if decode_err != nil {
			return
		}
		defer qoi.destroy(img)

		testing.expect_value(t, img.width, width)
		testing.expect_value(t, img.height, height)
		testing.expect_value(t, img.channels, 4)
		testing.expect_value(t, img.depth, 8)
	}
}
