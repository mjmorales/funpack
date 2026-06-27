package main

import funpack_runtime "../../runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:hash"
import "core:image"
import qoi "core:image/qoi"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

SHOT_TOOL_NAME :: "inspect_screenshot"

SHOT_PNG_SIGNATURE := [8]u8{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}

SHOT_DEFLATE_MAX_STORED :: 65535

SHOT_DIR_ENV :: "FUNPACK_SCREENSHOT_DIR"

SHOT_DEFAULT_DIR :: "/tmp/funpack-mcp"

SHOT_FILE_PREFIX :: "funpack-screenshot-"

mcp_screenshot_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	if dispatch.name != SHOT_TOOL_NAME {
		return "", false
	}
	return shot_handle(dispatch, allocator), true
}

shot_handle :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	session_id, has_session := funpack_runtime.json_string_field(dispatch.arguments, "session_id")
	if !has_session {
		return mcp_tool_error(dispatch.id, mcp_missing_string_field("session_id", dispatch.name, allocator), allocator)
	}
	tick, has_tick := funpack_runtime.json_int_field(dispatch.arguments, "tick")
	if !has_tick {
		return mcp_tool_error(dispatch.id, Mcp_Error{
			category = .Invalid_Input,
			message  = "inspect_screenshot missing required integer field: tick",
		}, allocator)
	}

	include, has_include := funpack_runtime.json_bool_field(dispatch.arguments, "include_drawlist")
	overlay, has_overlay := funpack_runtime.json_bool_field(dispatch.arguments, "overlay")
	branch, has_branch := funpack_runtime.json_string_field(dispatch.arguments, "branch")
	line := shot_build_request_line(tick, include, has_include, overlay, has_overlay, branch, has_branch, allocator)

	response, found := mcp_session_registry_request(dispatch.registry, session_id, line)
	if !found {
		return mcp_tool_error(dispatch.id, mcp_unknown_session_error(session_id), allocator)
	}

	parsed, ok_field, error_text, result_obj := shot_parse_response(response, allocator)
	if !parsed {
		return mcp_tool_error(dispatch.id, Mcp_Error{
			category = .Internal,
			message  = "the §28 screenshot response was not a valid envelope",
			detail   = response,
		}, allocator)
	}
	if !ok_field {
		return mcp_tool_error(dispatch.id, shot_map_refusal(error_text), allocator)
	}

	pixels_b64, has_pixels := funpack_runtime.json_string_field(result_obj, "pixels")
	if !has_pixels {
		return mcp_tool_error(dispatch.id, Mcp_Error{
			category = .Internal,
			message  = "the §28 screenshot result carried no pixels field",
		}, allocator)
	}

	png_bytes, transcoded := shot_qoi_to_png_bytes(pixels_b64, allocator)
	if !transcoded {
		return mcp_tool_error(dispatch.id, Mcp_Error{
			category = .Internal,
			message  = "decoding the §28 QOI frame to PNG failed",
		}, allocator)
	}

	dir := shot_output_dir(allocator)
	path, written := shot_write_png_file(dir, png_bytes, tick, shot_timestamp(allocator), allocator)
	if !written {
		return mcp_tool_error(dispatch.id, Mcp_Error{
			category = .Internal,
			message  = "writing the screenshot PNG to disk failed",
			detail   = dir,
		}, allocator)
	}

	include_pixels, _ := funpack_runtime.json_bool_field(dispatch.arguments, "include_pixels")
	meta := shot_render_metadata(result_obj, include && has_include, path, allocator)
	content := shot_build_content(meta, png_bytes, include_pixels, allocator)
	tool_result := Mcp_Tool_Result{content = content, is_error = false}
	return mcp_render_tool_result(dispatch.id, tool_result, allocator)
}

shot_build_content :: proc(meta: string, png: []u8, include_pixels: bool, allocator := context.allocator) -> []Mcp_Content {
	if !include_pixels {
		content := make([]Mcp_Content, 1, allocator)
		content[0] = mcp_text_content(meta)
		return content
	}
	content := make([]Mcp_Content, 2, allocator)
	content[0] = mcp_text_content(meta)
	content[1] = mcp_image_content(base64.encode(png, base64.ENC_TABLE, allocator), "image/png")
	return content
}
shot_build_request_line :: proc(
	tick: i64,
	include: bool,
	has_include: bool,
	overlay: bool,
	has_overlay: bool,
	branch: string,
	has_branch: bool,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"v":`)
	strings.write_int(&b, funpack_runtime.INTROSPECT_PROTOCOL_VERSION)
	strings.write_string(&b, `,"id":1,"cmd":"screenshot","args":{"tick":`)
	strings.write_i64(&b, tick)
	if has_include {
		strings.write_string(&b, `,"include_drawlist":`)
		strings.write_string(&b, include ? "true" : "false")
	}
	if has_overlay {
		strings.write_string(&b, `,"overlay":`)
		strings.write_string(&b, overlay ? "true" : "false")
	}
	if has_branch {
		strings.write_string(&b, `,"branch":`)
		funpack_runtime.write_json_string(&b, branch)
	}
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

shot_parse_response :: proc(
	line: string,
	allocator := context.allocator,
) -> (parsed: bool, ok_field: bool, error_text: string, result_obj: json.Object) {
	value, parse_err := json.parse(transmute([]u8)line, json.DEFAULT_SPECIFICATION, true, allocator)
	if parse_err != .None {
		return false, false, "", nil
	}
	object, is_object := value.(json.Object)
	if !is_object {
		return false, false, "", nil
	}
	if flag, has_ok := object["ok"]; has_ok {
		if boolean, is_bool := flag.(json.Boolean); is_bool {
			ok_field = bool(boolean)
		}
	}
	if ok_field {
		if nested, has_result := object["result"]; has_result {
			if result_object, result_ok := nested.(json.Object); result_ok {
				result_obj = result_object
			}
		}
	} else {
		error_text, _ = funpack_runtime.json_string_field(object, "error")
	}
	return true, ok_field, error_text, result_obj
}

shot_map_refusal :: proc(runtime_text: string) -> Mcp_Error {
	if shot_is_input_refusal(runtime_text) {
		return Mcp_Error{category = .Refused, message = runtime_text}
	}
	err := Mcp_Error {
		category = .Session,
		message  = "inspect_screenshot crosses the render/present boundary, which this funpack binary cannot serve — pixel capture needs a funpack built with FUNPACK_LIVE. Use inspect_draw_list for the deterministic render projection: it is screenshot's sim-pure twin and always serves headless (it IS the determinism-path render output)",
	}
	if runtime_text != "" {
		err.detail = strings.concatenate({"runtime: ", runtime_text}, context.temp_allocator)
	}
	return err
}

shot_is_input_refusal :: proc(runtime_text: string) -> bool {
	markers := [?]string{"tick out of range", "missing args.tick", "unknown branch"}
	for marker in markers {
		if strings.contains(runtime_text, marker) {
			return true
		}
	}
	return false
}

shot_render_metadata :: proc(result_obj: json.Object, include_drawlist: bool, path: string, allocator := context.allocator) -> string {
	tick, _ := funpack_runtime.json_int_field(result_obj, "tick")
	width, _ := funpack_runtime.json_int_field(result_obj, "width")
	height, _ := funpack_runtime.json_int_field(result_obj, "height")

	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"tick":`)
	strings.write_i64(&b, tick)
	strings.write_string(&b, `,"width":`)
	strings.write_i64(&b, width)
	strings.write_string(&b, `,"height":`)
	strings.write_i64(&b, height)
	strings.write_string(&b, `,"path":`)
	funpack_runtime.write_json_string(&b, path)
	if include_drawlist {
		if commands, has_commands := result_obj["commands"]; has_commands {
			if array, is_array := commands.(json.Array); is_array {
				strings.write_string(&b, `,"commands":[`)
				for cmd, i in array {
					if i > 0 {
						strings.write_byte(&b, ',')
					}
					text, _ := cmd.(json.String)
					funpack_runtime.write_json_string(&b, string(text))
				}
				strings.write_byte(&b, ']')
			}
		}
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

shot_qoi_to_png_bytes :: proc(base64_qoi: string, allocator := context.allocator) -> (png: []u8, ok: bool) {
	// qoi.destroy frees via context.allocator, so pin it to `allocator` to match the load.
	context.allocator = allocator

	qoi_bytes, decode_err := base64.decode(base64_qoi, base64.DEC_TABLE, allocator)
	if decode_err != nil {
		return nil, false
	}
	img, load_err := qoi.load_from_bytes(qoi_bytes, image.Options{}, allocator)
	if load_err != nil || img == nil {
		return nil, false
	}
	defer qoi.destroy(img)

	pixels := img.pixels.buf[:]
	png_bytes, encoded := shot_encode_png(pixels, img.width, img.height, img.channels, allocator)
	if !encoded {
		return nil, false
	}
	return png_bytes, true
}

shot_output_dir :: proc(allocator := context.allocator) -> string {
	if configured, has := os.lookup_env(SHOT_DIR_ENV, allocator); has && configured != "" {
		return configured
	}
	return SHOT_DEFAULT_DIR
}

shot_timestamp :: proc(allocator := context.allocator) -> string {
	now := time.now()
	year, month, day := time.date(now)
	hour, minute, second, nanos := time.precise_clock_from_time(now)

	b := strings.builder_make(allocator)
	shot_write_pad(&b, year, 4)
	shot_write_pad(&b, int(month), 2)
	shot_write_pad(&b, day, 2)
	strings.write_byte(&b, '-')
	shot_write_pad(&b, hour, 2)
	shot_write_pad(&b, minute, 2)
	shot_write_pad(&b, second, 2)
	strings.write_byte(&b, '-')
	shot_write_pad(&b, nanos, 9)
	return strings.to_string(b)
}

shot_write_pad :: proc(b: ^strings.Builder, value: int, width: int) {
	buf: [32]u8
	text := strconv.write_int(buf[:], i64(value), 10)
	for _ in len(text) ..< width {
		strings.write_byte(b, '0')
	}
	strings.write_string(b, text)
}

shot_screenshot_path :: proc(dir: string, tick: i64, timestamp: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, SHOT_FILE_PREFIX)
	strings.write_string(&b, timestamp)
	strings.write_string(&b, "-tick")
	strings.write_i64(&b, tick)
	strings.write_string(&b, ".png")
	joined, _ := filepath.join({dir, strings.to_string(b)}, allocator)
	return joined
}

shot_write_png_file :: proc(
	dir: string,
	png: []u8,
	tick: i64,
	timestamp: string,
	allocator := context.allocator,
) -> (path: string, ok: bool) {
	if mk_err := os.make_directory_all(dir); mk_err != nil && !os.is_dir(dir) {
		return "", false
	}
	path = shot_screenshot_path(dir, tick, timestamp, allocator)
	if write_err := os.write_entire_file(path, png); write_err != nil {
		return "", false
	}
	return path, true
}

shot_encode_png :: proc(
	pixels: []u8,
	width: int,
	height: int,
	channels: int,
	allocator := context.allocator,
) -> (png: []u8, ok: bool) {
	if width <= 0 || height <= 0 {
		return nil, false
	}
	color_type: u8
	switch channels {
	case 3:
		color_type = 2
	case 4:
		color_type = 6
	case:
		return nil, false
	}
	if len(pixels) < width * height * channels {
		return nil, false
	}

	b := strings.builder_make(allocator)
	for sig_byte in SHOT_PNG_SIGNATURE {
		strings.write_byte(&b, sig_byte)
	}

	ihdr: [13]u8
	shot_put_u32_be(ihdr[0:4], u32(width))
	shot_put_u32_be(ihdr[4:8], u32(height))
	ihdr[8] = 8
	ihdr[9] = color_type
	ihdr[10] = 0
	ihdr[11] = 0
	ihdr[12] = 0
	shot_write_chunk(&b, "IHDR", ihdr[:])

	stride := width * channels
	raw := make([]u8, height * (stride + 1), allocator)
	for y in 0 ..< height {
		dst := y * (stride + 1)
		raw[dst] = 0
		src := y * stride
		copy(raw[dst + 1:dst + 1 + stride], pixels[src:src + stride])
	}

	idat := shot_zlib_stored(raw, allocator)
	shot_write_chunk(&b, "IDAT", idat)
	shot_write_chunk(&b, "IEND", nil)

	return transmute([]u8)strings.to_string(b), true
}

shot_zlib_stored :: proc(data: []u8, allocator := context.allocator) -> []u8 {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, 0x78)
	strings.write_byte(&b, 0x01)

	remaining := data
	for {
		chunk_len := len(remaining)
		final := chunk_len <= SHOT_DEFLATE_MAX_STORED
		if !final {
			chunk_len = SHOT_DEFLATE_MAX_STORED
		}
		strings.write_byte(&b, final ? 0x01 : 0x00)
		len_u16 := u16(chunk_len)
		strings.write_byte(&b, u8(len_u16 & 0xff))
		strings.write_byte(&b, u8((len_u16 >> 8) & 0xff))
		nlen := ~len_u16
		strings.write_byte(&b, u8(nlen & 0xff))
		strings.write_byte(&b, u8((nlen >> 8) & 0xff))
		for i in 0 ..< chunk_len {
			strings.write_byte(&b, remaining[i])
		}
		if final {
			break
		}
		remaining = remaining[chunk_len:]
	}

	adler := hash.adler32(data)
	trailer: [4]u8
	shot_put_u32_be(trailer[:], adler)
	for trailer_byte in trailer {
		strings.write_byte(&b, trailer_byte)
	}
	return transmute([]u8)strings.to_string(b)
}

shot_write_chunk :: proc(b: ^strings.Builder, type_code: string, data: []u8) {
	length: [4]u8
	shot_put_u32_be(length[:], u32(len(data)))
	for length_byte in length {
		strings.write_byte(b, length_byte)
	}
	strings.write_string(b, type_code)
	for data_byte in data {
		strings.write_byte(b, data_byte)
	}

	crc_input := make([]u8, len(type_code) + len(data), context.temp_allocator)
	copy(crc_input[:len(type_code)], transmute([]u8)type_code)
	copy(crc_input[len(type_code):], data)
	crc := hash.crc32(crc_input)
	crc_bytes: [4]u8
	shot_put_u32_be(crc_bytes[:], crc)
	for crc_byte in crc_bytes {
		strings.write_byte(b, crc_byte)
	}
}

shot_put_u32_be :: proc(dst: []u8, value: u32) {
	dst[0] = u8((value >> 24) & 0xff)
	dst[1] = u8((value >> 16) & 0xff)
	dst[2] = u8((value >> 8) & 0xff)
	dst[3] = u8(value & 0xff)
}
