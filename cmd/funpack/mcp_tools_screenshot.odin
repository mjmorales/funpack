// The SCREENSHOT tool dispatch family — the arm of the tools/call chain
// (mcp_server.odin MCP_DISPATCH_CHAIN) that owns inspect_screenshot over a NAMED
// session. Per the resolved ADR this arm hand-rolls a minimal stored-block PNG encoder
// (core has no PNG encoder — core:image/png is decode-only) so MCP ImageContent
// carries a renderable image/png; it returns an .Image content block, not text. This
// file is ONE dispatch seam — it owns ONLY this file's dispatch proc, never
// mcp_handle_tools_call.
//
// THE PIPELINE (QOI → PNG over Odin core):
//   §28 screenshot fold → base64-QOI pixels → base64.decode → qoi.load_from_bytes
//   (RGBA8/RGB8, tight row-major) → shot_encode_png (hand-rolled, below) → base64 →
//   MCP image content block (mimeType image/png) + a metadata text block.
//
// EVERY package-level proc/type here is prefixed `shot_` so package main carries no
// duplicate symbols when all six family files merge (the merge-clean invariant).
//
// PRESENT-BOUNDARY REFUSAL:
// screenshot is the one observe command that crosses the render/present boundary — a
// funpack binary built WITHOUT FUNPACK_LIVE answers with a §28 ok:false refusal. The
// arm reframes that as a Session-category envelope naming inspect_draw_list (the
// sim-pure, always-serving twin) as the headless substitute. A CALLER-input refusal
// (bad tick, unknown branch) is forwarded unreframed — the caller fixes the argument.
package main

import funpack_runtime "../../runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:hash"
import "core:image"
import qoi "core:image/qoi"
import "core:strings"

// SHOT_TOOL_NAME is the MCP tool this family claims — the generated Tool_Spec name
// (api_contract.gen.odin: inspect_screenshot → §28 command "screenshot"). The arm
// matches on this and declines (handled=false) every other tool so they flow down
// the chain.
SHOT_TOOL_NAME :: "inspect_screenshot"

// SHOT_PNG_SIGNATURE is the fixed 8-byte PNG file signature (PNG spec §5.2): the
// high bit catches 7-bit transports, the CR-LF/LF pair catches newline mangling. A
// valid PNG begins with exactly these bytes — the structural-validity test asserts it.
SHOT_PNG_SIGNATURE := [8]u8{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}

// SHOT_DEFLATE_MAX_STORED is the maximum payload one DEFLATE stored block carries: a
// stored block's LEN field is a u16, so 65535 bytes per block (PNG spec / RFC 1951
// §3.2.4). A scanline stream larger than this splits across several stored blocks.
SHOT_DEFLATE_MAX_STORED :: 65535

// mcp_screenshot_dispatch is the screenshot family's arm. It claims inspect_screenshot,
// folds the §28 screenshot capture through the named session, transcodes the QOI frame
// to a hand-rolled PNG, and returns an MCP image content block + metadata — all as a
// SUCCESSFUL tools/call (a domain failure rides the IsError envelope, never a JSON-RPC
// error). Every other tool flows past (handled=false). ZERO edits to the chain caller.
mcp_screenshot_dispatch :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> (result: string, handled: bool) {
	if dispatch.name != SHOT_TOOL_NAME {
		return "", false
	}
	return shot_handle(dispatch, allocator), true
}

// shot_handle runs the inspect_screenshot pipeline end to end and renders the JSON-RPC
// result line. Each domain failure (missing/typed arg, stale session, present-boundary
// refusal, transcode fault) maps to the in-band IsError envelope through mcp_error.odin
// — the model reads the category and self-corrects. The happy path returns BOTH a PNG
// image block (the model SEES the frame) and a metadata text block on one result.
shot_handle :: proc(dispatch: Mcp_Dispatch, allocator := context.allocator) -> string {
	session_id, has_session := funpack_runtime.json_string_field(dispatch.arguments, "session_id")
	if !has_session {
		return shot_error_line(dispatch.id, Mcp_Error{
			category = .Invalid_Input,
			message  = "inspect_screenshot missing required string field: session_id",
		}, allocator)
	}
	tick, has_tick := funpack_runtime.json_int_field(dispatch.arguments, "tick")
	if !has_tick {
		return shot_error_line(dispatch.id, Mcp_Error{
			category = .Invalid_Input,
			message  = "inspect_screenshot missing required integer field: tick",
		}, allocator)
	}

	// Marshal the §28 args (tick, optional include_drawlist, optional branch) into a
	// request line. An unset optional is elided so the runtime defaults (visual-only,
	// canonical timeline) — exactly as observe_screenshot reads its args.
	include, has_include := funpack_runtime.json_bool_field(dispatch.arguments, "include_drawlist")
	branch, has_branch := funpack_runtime.json_string_field(dispatch.arguments, "branch")
	line := shot_build_request_line(tick, include, has_include, branch, has_branch, allocator)

	response, found := mcp_session_registry_request(dispatch.registry, session_id, line)
	if !found {
		// A stale/unknown session is a Session-category refusal — the session is never
		// fabricated (the registry returns found=false), so the model knows to re-open.
		return shot_error_line(dispatch.id, Mcp_Error{
			category = .Session,
			message  = "unknown or ended session — open one with session_start",
			detail   = session_id,
		}, allocator)
	}

	parsed, ok_field, error_text, result_obj := shot_parse_response(response, allocator)
	if !parsed {
		return shot_error_line(dispatch.id, Mcp_Error{
			category = .Internal,
			message  = "the §28 screenshot response was not a valid envelope",
			detail   = response,
		}, allocator)
	}
	if !ok_field {
		// A §28 refusal — reframe a present-boundary crossing, forward a caller-input
		// mistake unchanged (shot_map_refusal).
		return shot_error_line(dispatch.id, shot_map_refusal(error_text), allocator)
	}

	pixels_b64, has_pixels := funpack_runtime.json_string_field(result_obj, "pixels")
	if !has_pixels {
		return shot_error_line(dispatch.id, Mcp_Error{
			category = .Internal,
			message  = "the §28 screenshot result carried no pixels field",
		}, allocator)
	}

	png_b64, transcoded := shot_qoi_to_png_base64(pixels_b64, allocator)
	if !transcoded {
		return shot_error_line(dispatch.id, Mcp_Error{
			category = .Internal,
			message  = "decoding the §28 QOI frame to PNG failed",
		}, allocator)
	}

	// BOTH content blocks on one result: the PNG (image/png) the model SEES, and the
	// structured geometry metadata as a text block. The metadata carries
	// {tick,width,height,commands?}.
	meta := shot_render_metadata(result_obj, include && has_include, allocator)
	content := make([]Mcp_Content, 2, allocator)
	content[0] = mcp_image_content(png_b64, "image/png")
	content[1] = mcp_text_content(meta)
	tool_result := Mcp_Tool_Result{content = content, is_error = false}
	return mcp_render_tool_result(dispatch.id, tool_result, allocator)
}

// shot_error_line renders a domain failure as a SUCCESSFUL tools/call carrying the
// IsError envelope (mcp_error.odin) on the dispatch id — never a JSON-RPC error object.
shot_error_line :: proc(id: Mcp_Id, err: Mcp_Error, allocator := context.allocator) -> string {
	return mcp_render_tool_result(id, mcp_tool_error_result(err, allocator), allocator)
}

// shot_build_request_line marshals the §28 screenshot request line: the fixed envelope
// (v, id, cmd) plus the args object. `id` is a fixed 1 — the session fold is synchronous
// (one request, one response) so the inner id only needs to round-trip, not correlate.
// Optional args are elided when unset so the runtime applies its defaults.
shot_build_request_line :: proc(
	tick: i64,
	include: bool,
	has_include: bool,
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
	if has_branch {
		strings.write_string(&b, `,"branch":`)
		funpack_runtime.write_json_string(&b, branch)
	}
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

// shot_parse_response parses one §28 response line into its (ok, error, result) parts.
// parsed=false for a line that is not a JSON object. On ok:true `result_obj` is the
// result object; on ok:false `error_text` is the runtime's refusal string. The shapes
// mirror ok_response_open / error_response (introspect.odin).
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

// shot_map_refusal owns the inspect_screenshot present-boundary diagnostic: a
// CALLER-input refusal (bad tick, unknown branch) is forwarded as the runtime stated
// it (the caller fixes the argument), while the present-boundary crossing —
// everything else — is reframed as a Session-category envelope naming
// inspect_draw_list, the sim-pure headless substitute. The runtime text rides along
// as detail for fidelity.
shot_map_refusal :: proc(runtime_text: string) -> Mcp_Error {
	if shot_is_input_refusal(runtime_text) {
		return Mcp_Error{category = .Session, message = runtime_text}
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

// shot_is_input_refusal reports whether a §28 screenshot refusal is a caller-side
// argument mistake (a bad/missing tick, an unknown branch) rather than the present-
// boundary crossing. The markers are the runtime's stable refusal substrings (from
// observe_screenshot in introspect.odin); the present-boundary refusal is everything
// else.
shot_is_input_refusal :: proc(runtime_text: string) -> bool {
	markers := [?]string{"tick out of range", "missing args.tick", "unknown branch"}
	for marker in markers {
		if strings.contains(runtime_text, marker) {
			return true
		}
	}
	return false
}

// shot_render_metadata renders the screenshot metadata text block from the §28
// result: {tick,width,height} always, commands[] when include_drawlist rode along
// (the result carries them as text commands from observe_screenshot in
// introspect.odin). Built with the same write_json_string idiom as the §28 renderers,
// so it is byte-stable.
shot_render_metadata :: proc(result_obj: json.Object, include_drawlist: bool, allocator := context.allocator) -> string {
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

// shot_qoi_to_png_base64 is the §28-pixels → model-visible-image transcode: base64-
// decode the QOI payload, decode QOI → RGBA8/RGB8 (core:image/qoi, the runtime's encode
// inverted), encode a PNG by hand (shot_encode_png), then base64 the PNG for the MCP
// data field. ok=false on any decode/encode failure (the caller maps it to an internal
// IsError). The decoded buffer is already tight row-major, the shape the PNG encoder
// filters per scanline.
shot_qoi_to_png_base64 :: proc(base64_qoi: string, allocator := context.allocator) -> (png_base64: string, ok: bool) {
	// Run the whole transcode under `allocator`: qoi.load_from_bytes allocates on the
	// AMBIENT context.allocator (not its `allocator` param for the inner buffers it
	// resizes via context) and qoi.destroy frees on context.allocator too, so the load
	// and the destroy MUST see the same allocator or destroy cross-frees (a bad free).
	// Pinning context.allocator here keeps load → destroy consistent.
	context.allocator = allocator

	qoi_bytes, decode_err := base64.decode(base64_qoi, base64.DEC_TABLE, allocator)
	if decode_err != nil {
		return "", false
	}
	img, load_err := qoi.load_from_bytes(qoi_bytes, image.Options{}, allocator)
	if load_err != nil || img == nil {
		return "", false
	}
	defer qoi.destroy(img)

	pixels := img.pixels.buf[:]
	png_bytes, encoded := shot_encode_png(pixels, img.width, img.height, img.channels, allocator)
	if !encoded {
		return "", false
	}
	return base64.encode(png_bytes, base64.ENC_TABLE, allocator), true
}

// shot_encode_png hand-rolls a minimal PNG over the tight row-major RGBA8/RGB8 buffer —
// the encoder Odin core lacks (core:image/png is decode-only; the ADR-sanctioned net-new
// subsystem). It emits: the 8-byte signature, an IHDR chunk (8-bit truecolor, no
// interlace), an IDAT chunk carrying a zlib stream of STORED (uncompressed) DEFLATE
// blocks over the filter-0 scanlines with an adler32 trailer, and IEND. Every chunk's
// CRC32 and the stream's adler32 come from core:hash (Odin-first). ok=false on a
// degenerate frame (no pixels, an unsupported channel count, a buffer too short).
//
// STORED, not compressed: a stored-block zlib stream is the simplest spec-valid DEFLATE
// — no Huffman, no LZ77 — so the encoder is small and obviously correct. The cost is
// size (the PNG is ~raw), acceptable for a debug screenshot the model views once.
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
	// Truecolor PNG: 3 channels → color type 2 (RGB), 4 → color type 6 (RGBA). The
	// runtime always encodes 4, but the decode honors the QOI header, so support both
	// rather than assume.
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

	// IHDR: width, height (big-endian u32 each), bit depth 8, color type, compression
	// 0, filter 0, interlace 0 (PNG spec §11.2.2).
	ihdr: [13]u8
	shot_put_u32_be(ihdr[0:4], u32(width))
	shot_put_u32_be(ihdr[4:8], u32(height))
	ihdr[8] = 8
	ihdr[9] = color_type
	ihdr[10] = 0
	ihdr[11] = 0
	ihdr[12] = 0
	shot_write_chunk(&b, "IHDR", ihdr[:])

	// The filtered scanline stream: each row is prefixed with filter-type byte 0 (None)
	// then its raw bytes (PNG spec §9 — filter 0 stores the row verbatim). This is the
	// payload the zlib stored-block stream wraps.
	stride := width * channels
	raw := make([]u8, height * (stride + 1), allocator)
	for y in 0 ..< height {
		dst := y * (stride + 1)
		raw[dst] = 0 // filter type: None
		src := y * stride
		copy(raw[dst + 1:dst + 1 + stride], pixels[src:src + stride])
	}

	idat := shot_zlib_stored(raw, allocator)
	shot_write_chunk(&b, "IDAT", idat)
	shot_write_chunk(&b, "IEND", nil)

	return transmute([]u8)strings.to_string(b), true
}

// shot_zlib_stored wraps `data` in a zlib stream of STORED DEFLATE blocks (RFC 1950 +
// RFC 1951 §3.2.4): the 2-byte zlib header (CMF=0x78 deflate/32K window, FLG=0x01 so
// CMF*256+FLG ≡ 0 mod 31), then one or more stored blocks (BFINAL on the last, BTYPE=00,
// LEN/~LEN as little-endian u16 each, then the literal bytes), then the big-endian
// adler32 of the UNCOMPRESSED data. A stored block carries at most 65535 bytes, so a
// larger payload splits across blocks.
shot_zlib_stored :: proc(data: []u8, allocator := context.allocator) -> []u8 {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, 0x78) // CMF: deflate, 32K window
	strings.write_byte(&b, 0x01) // FLG: check bits so (0x78<<8 | 0x01) % 31 == 0

	remaining := data
	for {
		chunk_len := len(remaining)
		final := chunk_len <= SHOT_DEFLATE_MAX_STORED
		if !final {
			chunk_len = SHOT_DEFLATE_MAX_STORED
		}
		strings.write_byte(&b, final ? 0x01 : 0x00) // BFINAL on the last block, BTYPE=00
		// LEN then one's-complement ~LEN, little-endian u16 each.
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

	// adler32 of the UNCOMPRESSED data, big-endian, closes the zlib stream.
	adler := hash.adler32(data)
	trailer: [4]u8
	shot_put_u32_be(trailer[:], adler)
	for trailer_byte in trailer {
		strings.write_byte(&b, trailer_byte)
	}
	return transmute([]u8)strings.to_string(b)
}

// shot_write_chunk appends one PNG chunk (PNG spec §5.3): a big-endian u32 length of
// the data, the 4-byte type code, the data, then a big-endian u32 CRC32 over the TYPE
// + DATA (not the length). The CRC is core:hash.crc32 (seed 0 = PNG's init/final-xor),
// Odin-first.
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

	// CRC over type code + data. Concatenate into one contiguous buffer so the single
	// crc32 call sees the exact chunk-CRC input the PNG spec defines.
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

// shot_put_u32_be writes a u32 big-endian into a 4-byte slice — the byte order PNG
// chunk lengths, CRCs, IHDR fields, and the zlib adler32 trailer all use (PNG/zlib are
// network-order). The caller passes a slice exactly 4 bytes long.
shot_put_u32_be :: proc(dst: []u8, value: u32) {
	dst[0] = u8((value >> 24) & 0xff)
	dst[1] = u8((value >> 16) & 0xff)
	dst[2] = u8((value >> 8) & 0xff)
	dst[3] = u8(value & 0xff)
}
