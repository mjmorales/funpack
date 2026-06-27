package funpack_runtime

@(require) import "core:encoding/base64"
@(require) import "core:image/qoi"
@(require) import "core:testing"

when #config(FUNPACK_LIVE, false) {

	@(private = "file")
	capture_probe_program :: proc() -> Program {
		program: Program
		program.entrypoint.logical_w = 160
		program.entrypoint.logical_h = 120
		return program
	}

	@(test)
	test_headless_capture_decodes_to_a_frame :: proc(t: ^testing.T) {
		program := capture_probe_program()

		rect := Draw_Rect {
			at    = Vec2{to_fixed(8), to_fixed(8)},
			size  = Vec2{to_fixed(16), to_fixed(16)},
			color = named_color(.White),
		}
		draw := Draw_List {
			cmds = []Draw_Cmd{rect},
		}

		encoded, width, height, ok := session_capture_frame(&program, draw, context.temp_allocator)

		testing.expect(t, ok, "headless capture must succeed via the dummy video driver — no display required")
		if !ok {
			return
		}
		testing.expect(t, width > 0 && height > 0, "captured frame must report a positive extent")
		testing.expect_value(t, width, 640)
		testing.expect_value(t, height, 480)

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
