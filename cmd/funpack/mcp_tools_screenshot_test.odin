// Deliberate spec for the inspect_screenshot family (mcp_tools_screenshot.odin) — the
// living junction test for the QOI→PNG transcode and the present-boundary dispatch arm.
// The headline test (test_shot_png_is_structurally_valid) is the ADR's named obligation:
// the hand-rolled PNG encoder emits a STRUCTURALLY VALID PNG — signature + IHDR + IDAT +
// IEND in order, every chunk's CRC32 correct — verified by re-parsing the bytes through
// core:image/png (the decode-only twin of the encoder core lacks). The rest pin the
// transcode round-trip (QOI→PNG preserves pixels), the dispatch claim (only
// inspect_screenshot is owned), the stale-session refusal, and the present-boundary
// refusal that names inspect_draw_list — the arm's whole contract surface.
//
// DEFINE-FREE FLOOR: these run in the default `odin test .` build (no FUNPACK_LIVE, no
// SDL). The PNG encoder + QOI codec are SDL-free, so the encoder is pinned in the same
// deterministic floor. A headless session's screenshot fold returns the §28 FUNPACK_LIVE
// refusal — which is PRECISELY the present-boundary path the refusal test exercises, so
// the headless floor is the natural home for that assertion, not a limitation.
//
// EVERY symbol here is prefixed `shot_` (tests included) so package main carries no
// duplicate symbol when all six family files merge.
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

// SHOT_FIXTURE is a minimal one-behavior artifact (mirrors mcp_session_test.odin's
// SESSION_FIXTURE) so the dispatch-arm tests can open a real headless session and fold a
// §28 screenshot through it — exercising the present-boundary refusal. Inlined per the
// self-contained-test standard (the runtime fixture is file-private).
SHOT_FIXTURE :: "funpack-artifact 18\n" +
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

// shot_stage_fixture writes SHOT_FIXTURE to a uniquely-named temp file and returns its
// path. ok=false (skip, never false-fail) when the temp root cannot be staged. The
// caller defers os.remove.
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

// shot_make_qoi_rgba encodes a small RGBA8 test frame to base64-QOI (the SAME shape
// session_capture_frame emits) so the transcode tests feed the arm/encoder a real QOI
// payload without a live present pass. The pattern is a deterministic per-pixel gradient
// so a round-trip can assert exact pixel preservation.
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

// test_shot_png_is_structurally_valid is THE named ADR obligation: the hand-rolled PNG
// encoder emits a structurally valid PNG. It asserts the 8-byte signature, the IHDR /
// IDAT / IEND chunk order, and EVERY chunk's CRC32 — by walking the chunk stream by hand
// and recomputing each CRC — then re-decodes the whole thing through core:image/png to
// prove a real PNG reader accepts it. A malformed length, a wrong CRC, or a missing
// chunk fails here.
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

	// 1) The 8-byte signature.
	for sig_byte, i in SHOT_PNG_SIGNATURE {
		testing.expect_value(t, encoded[i], sig_byte)
	}

	// 2) Walk the chunk stream, recompute each CRC, and collect the type order. A chunk
	// is [len:u32be][type:4][data:len][crc:u32be]; the CRC covers type+data.
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

	// 3) A real PNG decoder accepts the bytes and reads back the geometry — the
	// strongest structural assertion (the encoder's stored-block zlib + filter-0
	// scanlines + adler32 all check out under an independent reader). Load + destroy on
	// the default (heap) allocator so png.destroy (which frees on context.allocator)
	// matches the load allocation — a mismatch is a cross-allocator bad free.
	decoded, decode_err := png.load_from_bytes(encoded, image.Options{})
	testing.expect(t, decode_err == nil, "core:image/png decodes the hand-rolled PNG")
	if decoded != nil {
		testing.expect_value(t, decoded.width, width)
		testing.expect_value(t, decoded.height, height)
		png.destroy(decoded)
	}
}

// shot_walk_chunks walks a PNG chunk stream (post-signature), recomputing each chunk's
// CRC32 and collecting the type codes in order. ok=false on a truncated stream or a CRC
// mismatch. This is the structural validator the headline test asserts against — it does
// NOT trust the encoder, it re-derives every CRC the way a conformant reader would.
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

		crc_input := stream[type_start:crc_start] // type + data, the PNG CRC input
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

// shot_read_u32_be reads a big-endian u32 from a 4-byte slice — the inverse of
// shot_put_u32_be, used by the chunk walker to read lengths and CRCs.
@(private = "file")
shot_read_u32_be :: proc(src: []u8) -> u32 {
	return u32(src[0]) << 24 | u32(src[1]) << 16 | u32(src[2]) << 8 | u32(src[3])
}

// test_shot_qoi_to_png_round_trip pins the full transcode: a known RGBA frame → QOI →
// shot_qoi_to_png_bytes → core:image/png decode reproduces the ORIGINAL pixels exactly.
// This is the §28-pixels → on-disk-image path the arm runs, and it proves the encoder is
// lossless (stored blocks + filter-0 carry the bytes verbatim).
@(test)
test_shot_qoi_to_png_round_trip :: proc(t: ^testing.T) {
	width, height := 8, 6
	base64_qoi, raw_rgba := shot_make_qoi_rgba(width, height, context.temp_allocator)
	testing.expect(t, base64_qoi != "", "the QOI fixture encodes")

	png_bytes, ok := shot_qoi_to_png_bytes(base64_qoi, context.temp_allocator)
	testing.expect(t, ok, "the QOI→PNG transcode succeeds")

	// Load + destroy on the default (heap) allocator so png.destroy matches the load.
	decoded, load_err := png.load_from_bytes(png_bytes, image.Options{})
	testing.expect(t, load_err == nil, "the transcoded PNG decodes")
	if decoded == nil {
		return
	}
	defer png.destroy(decoded)
	testing.expect_value(t, decoded.width, width)
	testing.expect_value(t, decoded.height, height)
	testing.expect_value(t, decoded.channels, 4)
	// Exact pixel preservation — the round-trip is lossless.
	testing.expect(t, bytes.equal(decoded.pixels.buf[:], raw_rgba), "every pixel survives QOI→PNG")
}

// test_shot_screenshot_path_shape pins the PURE path builder: <dir>/funpack-screenshot-
// <timestamp>-tick<N>.png. No clock, no IO — the filename shape is deterministic given
// its inputs, so this fixes the on-disk naming contract the model reads back without
// touching the filesystem.
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

// test_shot_timestamp_shape pins the wall-clock stamp's fixed-width shape (YYYYMMDD-
// HHMMSS-<ns>): 8+1+6+1+9 = 25 chars with dashes at the two field boundaries. It asserts
// the SHAPE, not a value (the clock moves), so the lexically-sortable, collision-free
// filename contract holds without pinning real time.
@(test)
test_shot_timestamp_shape :: proc(t: ^testing.T) {
	stamp := shot_timestamp(context.temp_allocator)
	testing.expect_value(t, len(stamp), 25)
	testing.expect_value(t, stamp[8], '-')
	testing.expect_value(t, stamp[15], '-')
}

// test_shot_output_dir_default_and_env pins the directory resolver's two arms: unset,
// FUNPACK_SCREENSHOT_DIR falls back to SHOT_DEFAULT_DIR (the cwd-relative project
// folder); set to a non-empty value, that value wins verbatim. It mutates the process
// env and restores it, so it neither leaks nor depends on ambient state.
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

	_ = os.set_env(SHOT_DIR_ENV, "/custom/shots")
	testing.expect_value(t, shot_output_dir(context.temp_allocator), "/custom/shots")
}

// test_shot_write_png_file_round_trip pins the disk-write junction in the DEFAULT floor
// (no FUNPACK_LIVE): shot_write_png_file creates the directory on demand, writes a real
// hand-rolled PNG, returns the timestamped path, and a real PNG reader loads the file
// back with the original geometry. The live capture only runs under FUNPACK_LIVE, so
// this is where the write path is proven — SDL-free, deterministic.
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

	// A real PNG reader loads the file back — the bytes on disk ARE a valid PNG of the
	// captured geometry. Load + destroy on the default (heap) allocator so png.destroy
	// matches the load.
	decoded, load_err := png.load_from_file(path)
	testing.expect(t, load_err == nil, "core:image/png loads the written file")
	if decoded != nil {
		testing.expect_value(t, decoded.width, width)
		testing.expect_value(t, decoded.height, height)
		png.destroy(decoded)
	}
}

// test_shot_dispatch_declines_other_tools pins the chain contract: the arm claims ONLY
// inspect_screenshot and returns handled=false for any other tool, so unrelated tools
// flow down MCP_DISPATCH_CHAIN untouched. A nil registry is safe here — the decline
// returns before any registry access.
@(test)
test_shot_dispatch_declines_other_tools :: proc(t: ^testing.T) {
	for name in ([?]string{"inspect_draw_list", "inspect_pipeline", "session_start", "build"}) {
		_, handled := mcp_screenshot_dispatch(Mcp_Dispatch{name = name}, context.temp_allocator)
		testing.expect(t, !handled, "the arm declines tools it does not own")
	}
	// And it CLAIMS its own tool.
	_, handled := mcp_screenshot_dispatch(
		Mcp_Dispatch{name = SHOT_TOOL_NAME, id = Mcp_Id{kind = .Integer, integer = 1}},
		context.temp_allocator,
	)
	testing.expect(t, handled, "the arm claims inspect_screenshot")
}

// test_shot_present_boundary_end_to_end folds a §28 screenshot through a real session
// and asserts the arm's whole BUILD-CONDITIONED contract — the one piece of behavior
// that legitimately diverges by build, because session_capture_frame is itself a build
// split (session_live.odin, gated when #config(FUNPACK_LIVE)):
//
//   - DEFINE-FREE floor (no FUNPACK_LIVE): the capture is the no-op stub, the §28 fold
//     refuses, and the arm reframes that as a Session-category IsError naming
//     inspect_draw_list — NEVER a JSON-RPC error, NEVER a transcode over an absent frame.
//   - FUNPACK_LIVE build (the binary that ships the verb): the dummy SDL driver captures
//     headlessly, so the arm writes a PNG to disk and returns a metadata text block
//     (isError false) carrying the on-disk path the operator reads — no inline pixels.
//
// Pinning BOTH arms here keeps the test a living spec of the arm in the build it runs in,
// not a single-build snapshot that silently passes in the wrong one.
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
	// Either arm is a SUCCESSFUL tools/call — never a JSON-RPC error object.
	testing.expect(t, strings.contains(line, `"result":`), "the response is an in-band tools/call result")
	testing.expect(t, !strings.contains(line, `"error":{"code"`), "the response is NOT a JSON-RPC error object")

	when #config(FUNPACK_LIVE, false) {
		// The shipping build captures pixels, writes them to disk, and returns the PATH in
		// a metadata text block — never inline base64, never an image content block.
		testing.expect(t, strings.contains(line, `"isError":false`), "a live capture is not an error")
		testing.expect(t, strings.contains(line, `"type":"text"`), "the live capture returns a metadata text block")
		testing.expect(t, !strings.contains(line, `"type":"image"`), "the live capture carries NO inline image block")
		// The metadata envelope rides as an ESCAPED JSON string in the text block, so its
		// quotes are backslash-escaped on the wire (\"path\":\"…/funpack-screenshot-…\").
		testing.expect(t, strings.contains(line, `\"path\":`), "the metadata carries the on-disk path")
		testing.expect(t, strings.contains(line, "funpack-screenshot-"), "the path names a funpack screenshot file")
	} else {
		// The deterministic floor refuses and points at the sim-pure twin. The envelope
		// rides as an ESCAPED JSON string in the text block, so its quotes are escaped.
		testing.expect(t, strings.contains(line, `"isError":true`), "the headless refusal sets isError")
		testing.expect(t, strings.contains(line, `\"category\":\"session\"`), "the present-boundary refusal is Session-category")
		testing.expect(t, strings.contains(line, "inspect_draw_list"), "the refusal names the headless substitute")
	}
}

// shot_args_object builds a tools/call `arguments` json.Object {session_id, tick} the
// way the protocol loop hands the arm — by parsing a JSON literal, so the test exercises
// the SAME json.Object read path production uses (no hand-built map).
@(private = "file")
shot_args_object :: proc(session_id: string, tick: int, allocator := context.allocator) -> (obj: json.Object) {
	// Built via mcp_parse_request to mirror the real wire path exactly.
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"inspect_screenshot","arguments":{"session_id":`)
	funpack_runtime.write_json_string(&b, session_id)
	strings.write_string(&b, `,"tick":`)
	strings.write_int(&b, tick)
	strings.write_string(&b, `}}}`)
	request, _ := mcp_parse_request(strings.to_string(b), allocator)
	args := request.params["arguments"]
	object, _ := args.(json.Object)
	return object
}

// test_shot_stale_session_refusal pins the unknown-session path: a screenshot against an
// id the registry never minted is a Session-category IsError (the session is never
// fabricated), so the model knows to re-open rather than retry blindly.
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
	// The {category,...} envelope rides inside the text content as an ESCAPED JSON
	// string, so its quotes are backslash-escaped on the wire (\"category\":\"session\").
	testing.expect(t, strings.contains(line, `\"category\":\"session\"`), "the stale-session refusal is Session-category")
}

// test_shot_input_refusal_forwarded pins the caller-input branch of shot_map_refusal: a
// runtime refusal that is the caller's argument mistake (tick out of range, unknown
// branch) is forwarded as the runtime stated it — the caller fixes the argument, the MCP
// does NOT reframe it toward the present boundary.
@(test)
test_shot_input_refusal_forwarded :: proc(t: ^testing.T) {
	for marker in ([?]string{"tick out of range", "missing args.tick", "unknown branch — checkout an existing lineage"}) {
		err := shot_map_refusal(marker)
		testing.expect_value(t, err.category, Mcp_Error_Category.Session)
		testing.expect_value(t, err.message, marker)
		testing.expect(t, !strings.contains(err.message, "FUNPACK_LIVE"), "a caller-input refusal is forwarded unreframed")
	}
	// The present-boundary crossing (anything else) IS reframed toward inspect_draw_list.
	boundary := shot_map_refusal("screenshot crosses the render/present boundary — requires a FUNPACK_LIVE build with a display")
	testing.expect(t, strings.contains(boundary.message, "inspect_draw_list"), "the present-boundary refusal names the substitute")
	testing.expect(t, strings.contains(boundary.message, "FUNPACK_LIVE"), "the present-boundary refusal names the missing build flag")
}
