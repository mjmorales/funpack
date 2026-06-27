package main

import funpack_runtime "../../runtime"
import "core:bytes"
import "core:encoding/base64"
import "core:encoding/json"
import "core:hash"
import "core:image"
import png "core:image/png"
import qoi "core:image/qoi"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

SHOT_FIXTURE :: "funpack-artifact 19\n" +
	"[meta 2]\n" +
	"project introspect\n" +
	"version L5:0.1.0\n" +
	"[data 2]\n" +
	"data Stats 2 false\n" +
	"field hp Int -\n" +
	"field mana Int -\n" +
	"data Coord 1 false\n" +
	"field v Int -\n" +
	"[things 1]\n" +
	"thing Hero false 0 4\n" +
	"field pos Fixed =0\n" +
	"field stats Stats =Stats(hp=10,mana=4)\n" +
	"field home Coord =Coord(v=5)\n" +
	"field score Int =0\n" +
	"[behaviors 1]\n" +
	"behavior advance on:Hero stage:control contract:Update 0 1 1 1\n" +
	"param self Hero\n" +
	"emit Hero\n" +
	"node return 1\n" +
	"node with 1 2\n" +
	"node name self 0\n" +
	"node recfield pos 1\n" +
	"node binary add 2\n" +
	"node field pos 1\n" +
	"node name self 0\n" +
	"node fixed 4294967296 0\n" +
	"[pipeline_flattened 1]\n" +
	"step 0 stage:control behavior:advance\n" +
	"[setup 1]\n" +
	"spawn Hero 0\n" +
	"[entrypoint 1]\n" +
	"entrypoint main pipeline:Intro tick_hz:60 logical:160x120 bindings:bindings\n"

@(private = "file")
shot_stage_fixture :: proc(t: ^testing.T, name: string) -> (path: string, ok: bool) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	path, _ = filepath.join({base, name}, context.temp_allocator)
	if write_err := os.write_entire_file(path, SHOT_FIXTURE); write_err != nil {
		return "", false
	}
	return path, true
}

@(private = "file")
shot_make_qoi_rgba :: proc(width, height: int, allocator := context.allocator) -> (base64_qoi: string, raw_rgba: []u8) {
	raw_rgba = make([]u8, width * height * 4, allocator)
	for y in 0 ..< height {
		for x in 0 ..< width {
			i := (y * width + x) * 4
			raw_rgba[i + 0] = u8((x * 7) & 0xff)
			raw_rgba[i + 1] = u8((y * 11) & 0xff)
			raw_rgba[i + 2] = u8(((x + y) * 13) & 0xff)
			raw_rgba[i + 3] = 255
		}
	}
	img := image.Image {
		width    = width,
		height   = height,
		channels = 4,
		depth    = 8,
	}
	img.pixels.buf = make([dynamic]u8, len(raw_rgba), allocator)
	copy(img.pixels.buf[:], raw_rgba)
	buf: bytes.Buffer
	if encode_err := qoi.save_to_buffer(&buf, &img, qoi.Options{}, allocator); encode_err != nil {
		return "", raw_rgba
	}
	return base64.encode(bytes.buffer_to_bytes(&buf), base64.ENC_TABLE, allocator), raw_rgba
}

@(test)
test_shot_png_is_structurally_valid :: proc(t: ^testing.T) {
	width, height := 5, 3
	pixels := make([]u8, width * height * 4, context.temp_allocator)
	for i in 0 ..< len(pixels) {
		pixels[i] = u8(i & 0xff)
	}

	encoded, ok := shot_encode_png(pixels, width, height, 4, context.temp_allocator)
	testing.expect(t, ok, "the encoder accepts a well-formed RGBA frame")
	testing.expect(t, len(encoded) > 8, "the PNG is non-empty")

	for sig_byte, i in SHOT_PNG_SIGNATURE {
		testing.expect_value(t, encoded[i], sig_byte)
	}

	types, crcs_ok := shot_walk_chunks(encoded[8:])
	testing.expect(t, crcs_ok, "every chunk CRC32 recomputes correctly")
	testing.expect(t, len(types) >= 3, "the PNG carries at least IHDR, IDAT, IEND")
	testing.expect_value(t, types[0], "IHDR")
	testing.expect_value(t, types[len(types) - 1], "IEND")
	saw_idat := false
	for type_code in types {
		if type_code == "IDAT" {
			saw_idat = true
		}
	}
	testing.expect(t, saw_idat, "the PNG carries an IDAT chunk")

	decoded, decode_err := png.load_from_bytes(encoded, image.Options{})
	testing.expect(t, decode_err == nil, "core:image/png decodes the hand-rolled PNG")
	if decoded != nil {
		testing.expect_value(t, decoded.width, width)
		testing.expect_value(t, decoded.height, height)
		png.destroy(decoded)
	}
}

@(private = "file")
shot_walk_chunks :: proc(stream: []u8) -> (types: [dynamic]string, ok: bool) {
	types = make([dynamic]string, context.temp_allocator)
	offset := 0
	for offset + 12 <= len(stream) {
		length := int(shot_read_u32_be(stream[offset:offset + 4]))
		type_start := offset + 4
		data_start := type_start + 4
		crc_start := data_start + length
		if crc_start + 4 > len(stream) {
			return types, false
		}
		type_code := string(stream[type_start:type_start + 4])
		append(&types, type_code)

		crc_input := stream[type_start:crc_start]
		want := shot_read_u32_be(stream[crc_start:crc_start + 4])
		if hash.crc32(crc_input) != want {
			return types, false
		}
		offset = crc_start + 4
		if type_code == "IEND" {
			return types, true
		}
	}
	return types, false
}

@(private = "file")
shot_read_u32_be :: proc(src: []u8) -> u32 {
	return u32(src[0]) << 24 | u32(src[1]) << 16 | u32(src[2]) << 8 | u32(src[3])
}

@(test)
test_shot_qoi_to_png_round_trip :: proc(t: ^testing.T) {
	width, height := 8, 6
	base64_qoi, raw_rgba := shot_make_qoi_rgba(width, height, context.temp_allocator)
	testing.expect(t, base64_qoi != "", "the QOI fixture encodes")

	png_bytes, ok := shot_qoi_to_png_bytes(base64_qoi, context.temp_allocator)
	testing.expect(t, ok, "the QOI→PNG transcode succeeds")

	decoded, load_err := png.load_from_bytes(png_bytes, image.Options{})
	testing.expect(t, load_err == nil, "the transcoded PNG decodes")
	if decoded == nil {
		return
	}
	defer png.destroy(decoded)
	testing.expect_value(t, decoded.width, width)
	testing.expect_value(t, decoded.height, height)
	testing.expect_value(t, decoded.channels, 4)
	testing.expect(t, bytes.equal(decoded.pixels.buf[:], raw_rgba), "every pixel survives QOI→PNG")
}

@(test)
test_shot_screenshot_path_shape :: proc(t: ^testing.T) {
	p := shot_screenshot_path("/some/dir", 7, "20260619-193245-000000001", context.temp_allocator)
	testing.expect(t, strings.has_prefix(p, "/some/dir"), "the path joins under the given directory")
	testing.expect(
		t,
		strings.has_suffix(p, "funpack-screenshot-20260619-193245-000000001-tick7.png"),
		"the filename carries the prefix, timestamp, tick, and .png extension",
	)
}

@(test)
test_shot_timestamp_shape :: proc(t: ^testing.T) {
	stamp := shot_timestamp(context.temp_allocator)
	testing.expect_value(t, len(stamp), 25)
	testing.expect_value(t, stamp[8], '-')
	testing.expect_value(t, stamp[15], '-')
}

@(test)
test_shot_output_dir_default_and_env :: proc(t: ^testing.T) {
	saved, had := os.lookup_env(SHOT_DIR_ENV, context.temp_allocator)
	defer if had {
		_ = os.set_env(SHOT_DIR_ENV, saved)
	} else {
		_ = os.unset_env(SHOT_DIR_ENV)
	}

	_ = os.unset_env(SHOT_DIR_ENV)
	testing.expect_value(t, shot_output_dir(context.temp_allocator), SHOT_DEFAULT_DIR)
	testing.expect(t, strings.has_prefix(SHOT_DEFAULT_DIR, "/tmp/"), "the default lands under /tmp")

	_ = os.set_env(SHOT_DIR_ENV, "/custom/shots")
	testing.expect_value(t, shot_output_dir(context.temp_allocator), "/custom/shots")
}

@(test)
test_shot_build_content_pixels_opt_in :: proc(t: ^testing.T) {
	meta := `{"tick":0,"width":4,"height":2,"path":"/tmp/funpack-mcp/x.png"}`
	png := []u8{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0x01, 0x02}

	off := shot_build_content(meta, png, false, context.temp_allocator)
	testing.expect_value(t, len(off), 1)
	testing.expect_value(t, off[0].kind, Mcp_Content_Kind.Text)
	testing.expect_value(t, off[0].text, meta)

	on := shot_build_content(meta, png, true, context.temp_allocator)
	testing.expect_value(t, len(on), 2)
	testing.expect_value(t, on[0].kind, Mcp_Content_Kind.Text)
	testing.expect_value(t, on[0].text, meta)
	testing.expect_value(t, on[1].kind, Mcp_Content_Kind.Image)
	testing.expect_value(t, on[1].mime_type, "image/png")
	testing.expect_value(t, on[1].data, base64.encode(png, base64.ENC_TABLE, context.temp_allocator))
}

@(test)
test_shot_build_request_line_marshals_optionals :: proc(t: ^testing.T) {
	bare := shot_build_request_line(0, false, false, false, false, "", false, context.temp_allocator)
	testing.expect(t, strings.contains(bare, `"cmd":"screenshot"`), "the command is screenshot")
	testing.expect(t, strings.contains(bare, `"tick":0`), "tick is always marshalled")
	testing.expect(t, !strings.contains(bare, "include_drawlist"), "an unset include_drawlist is elided")
	testing.expect(t, !strings.contains(bare, "overlay"), "an unset overlay is elided")
	testing.expect(t, !strings.contains(bare, "branch"), "an unset branch is elided")

	full := shot_build_request_line(3, true, true, true, true, "fork-1", true, context.temp_allocator)
	testing.expect(t, strings.contains(full, `"tick":3`), "tick carries its value")
	testing.expect(t, strings.contains(full, `"include_drawlist":true`), "include_drawlist rides when set")
	testing.expect(t, strings.contains(full, `"overlay":true`), "overlay rides the wire when set (the dropped-arg fix)")
	testing.expect(t, strings.contains(full, `"branch":"fork-1"`), "branch rides when set")
}

@(test)
test_shot_write_png_file_round_trip :: proc(t: ^testing.T) {
	width, height := 4, 2
	pixels := make([]u8, width * height * 4, context.temp_allocator)
	for i in 0 ..< len(pixels) {
		pixels[i] = u8((i * 5) & 0xff)
	}
	png_bytes, encoded := shot_encode_png(pixels, width, height, 4, context.temp_allocator)
	testing.expect(t, encoded, "the test PNG encodes")

	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	dir, _ := filepath.join({base, "funpack-mcp-shot-write-test"}, context.temp_allocator)

	path, ok := shot_write_png_file(dir, png_bytes, 42, "20260619-193245-000000001", context.temp_allocator)
	testing.expect(t, ok, "the write succeeds (directory created on demand)")
	defer os.remove(path)
	defer os.remove(dir)
	testing.expect(t, os.is_file(path), "the screenshot file exists on disk")
	testing.expect(
		t,
		strings.has_suffix(path, "funpack-screenshot-20260619-193245-000000001-tick42.png"),
		"the written path carries the timestamped filename",
	)

	decoded, load_err := png.load_from_file(path)
	testing.expect(t, load_err == nil, "core:image/png loads the written file")
	if decoded != nil {
		testing.expect_value(t, decoded.width, width)
		testing.expect_value(t, decoded.height, height)
		png.destroy(decoded)
	}
}

@(test)
test_shot_dispatch_declines_other_tools :: proc(t: ^testing.T) {
	for name in ([?]string{"inspect_draw_list", "inspect_pipeline", "session_start", "build"}) {
		_, handled := mcp_screenshot_dispatch(Mcp_Dispatch{name = name}, context.temp_allocator)
		testing.expect(t, !handled, "the arm declines tools it does not own")
	}
	_, handled := mcp_screenshot_dispatch(
		Mcp_Dispatch{name = SHOT_TOOL_NAME, id = Mcp_Id{kind = .Integer, integer = 1}},
		context.temp_allocator,
	)
	testing.expect(t, handled, "the arm claims inspect_screenshot")
}

@(test)
test_shot_present_boundary_end_to_end :: proc(t: ^testing.T) {
	path, staged := shot_stage_fixture(t, "funpack-mcp-shot-present.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, open_result := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	testing.expect_value(t, open_result, funpack_runtime.Open_Session_Result.Ok)

	dispatch := Mcp_Dispatch {
		name      = SHOT_TOOL_NAME,
		id        = Mcp_Id{kind = .Integer, integer = 7},
		arguments = shot_args_object(id, 0, context.temp_allocator),
		registry  = &registry,
	}
	line, handled := mcp_screenshot_dispatch(dispatch, context.temp_allocator)
	testing.expect(t, handled, "the arm claims inspect_screenshot")
	testing.expect(t, strings.contains(line, `"result":`), "the response is an in-band tools/call result")
	testing.expect(t, !strings.contains(line, `"error":{"code"`), "the response is NOT a JSON-RPC error object")

	when #config(FUNPACK_LIVE, false) {
		testing.expect(t, strings.contains(line, `"isError":false`), "a live capture is not an error")
		testing.expect(t, strings.contains(line, `"type":"text"`), "the live capture returns a metadata text block")
		testing.expect(t, !strings.contains(line, `"type":"image"`), "the live capture carries NO inline image block")
		testing.expect(t, strings.contains(line, `\"path\":`), "the metadata carries the on-disk path")
		testing.expect(t, strings.contains(line, "funpack-screenshot-"), "the path names a funpack screenshot file")
	} else {
		testing.expect(t, strings.contains(line, `"isError":true`), "the headless refusal sets isError")
		testing.expect(t, strings.contains(line, `\"category\":\"session\"`), "the present-boundary refusal is Session-category")
		testing.expect(t, strings.contains(line, "inspect_draw_list"), "the refusal names the headless substitute")
	}
}

@(private = "file")
shot_args_object :: proc(session_id: string, tick: int, allocator := context.allocator) -> (obj: json.Object) {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"inspect_screenshot","arguments":{"session_id":`)
	funpack_runtime.write_json_string(&b, session_id)
	strings.write_string(&b, `,"tick":`)
	strings.write_int(&b, tick)
	strings.write_string(&b, `}}}`)
	request, _, _ := mcp_parse_request(strings.to_string(b), allocator)
	args := request.params["arguments"]
	object, _ := args.(json.Object)
	return object
}

@(test)
test_shot_stale_session_refusal :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	args := shot_args_object("sess-404", 0, context.temp_allocator)
	sid, has_sid := funpack_runtime.json_string_field(args, "session_id")
	testing.expect(t, has_sid, "the test args carry session_id")
	testing.expect_value(t, sid, "sess-404")
	dispatch := Mcp_Dispatch {
		name      = SHOT_TOOL_NAME,
		id        = Mcp_Id{kind = .Integer, integer = 9},
		arguments = args,
		registry  = &registry,
	}
	line, handled := mcp_screenshot_dispatch(dispatch, context.temp_allocator)
	testing.expect(t, handled, "the arm claims inspect_screenshot")
	testing.expect(t, strings.contains(line, `"isError":true`), "the stale-session refusal sets isError")
	testing.expect(t, strings.contains(line, `\"category\":\"session\"`), "the stale-session refusal is Session-category")
}

@(test)
test_shot_input_refusal_forwarded :: proc(t: ^testing.T) {
	for marker in ([?]string{"tick out of range", "missing args.tick", "unknown branch — checkout an existing lineage"}) {
		err := shot_map_refusal(marker)
		testing.expect_value(t, err.category, Mcp_Error_Category.Refused)
		testing.expect_value(t, err.message, marker)
		testing.expect(t, !strings.contains(err.message, "FUNPACK_LIVE"), "a caller-input refusal is forwarded unreframed")
	}
	boundary := shot_map_refusal("screenshot crosses the render/present boundary — requires a FUNPACK_LIVE build with a display")
	testing.expect(t, strings.contains(boundary.message, "inspect_draw_list"), "the present-boundary refusal names the substitute")
	testing.expect(t, strings.contains(boundary.message, "FUNPACK_LIVE"), "the present-boundary refusal names the missing build flag")
}
