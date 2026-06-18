// §28 observe-session acceptance: the duplex NDJSON request/response fold serves
// the observe set (signals / pipeline / trace / diff / replay_behavior /
// draw-list dump) as PURE reads of the retained committed COW chain, and
// observation is non-perturbing BY CONSTRUCTION — the digest-pin test below runs
// the full observe battery against a golden pong session and proves the observed
// session's canonical chain digests bit-identical to an unobserved reference run
// (per-tick AND session digests, plus world_versions_equal on the final commit).
//
// The envelope-shape tests pin EXACT response lines against a hand-built
// single-behavior artifact (the hot-reload fixture's shape): the envelope is
// versioned exact-match (§28 §2), so its byte shape is contract, not styling —
// a moved field is a protocol break the exact-string assertions catch.
package funpack_runtime

import "core:strings"
import "core:testing"

// INTROSPECT_FIXTURE is a minimal one-behavior artifact (the restore/reload
// fixture's build-A shape): a Hero with a Fixed pos advancing 1.0/tick, plus
// record-valued columns (stats/home) so the value encoding renders composite
// blackboards, not just scalars.
@(private = "file")
INTROSPECT_FIXTURE :: "funpack-artifact 18\n" +
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

// fixture_session loads the fixture and opens a session over `ticks` empty
// input snapshots — the shared opener the envelope-shape tests fold from.
@(private = "file")
fixture_session :: proc(
	t: ^testing.T,
	ticks: int,
	allocator := context.allocator,
) -> (
	program: ^Program,
	session: Debug_Session,
) {
	program = new(Program, allocator)
	loaded, err := load_program(INTROSPECT_FIXTURE, allocator)
	testing.expect(t, err == .None, "fixture artifact must load")
	program^ = loaded
	inputs := make([]Input, ticks, allocator)
	for i in 0 ..< ticks {
		inputs[i] = empty()
	}
	session = open_debug_session(program, inputs, NO_SEED, allocator)
	return program, session
}

// The pipeline observe answers the flattened §11 order with the exact-match
// versioned envelope — the full response line is pinned byte-for-byte.
@(test)
test_introspect_pipeline_envelope :: proc(t: ^testing.T) {
	_, session := fixture_session(t, 2)
	s := session
	response := session_request(&s, `{"id":1,"cmd":"pipeline"}`)
	expected :=
		`{"v":1,"id":1,"ok":true,"cmd":"pipeline","result":{"steps":[` +
		`{"ordinal":0,"stage":"control","behavior":"advance"}]}}`
	testing.expect_value(t, response, expected)
}

// The trace observe re-folds one tick and reports the behavior's (in → out):
// pre-eval blackboard, bound reads, returned value, post-tick committed
// blackboard — every funpack value a string in the artifact literal encoding.
@(test)
test_introspect_trace_behavior_transition :: proc(t: ^testing.T) {
	_, session := fixture_session(t, 3)
	s := session
	response := session_request(&s, `{"id":7,"cmd":"trace","args":{"tick":1,"behavior":"advance"}}`)
	expected :=
		`{"v":1,"id":7,"ok":true,"cmd":"trace","result":{"tick":1,"behavior":"advance","steps":[` +
		`{"ordinal":0,"instance":0,` +
		`"self_before":"Hero(home=Coord(v=5),pos=4294967296,score=0,stats=Stats(hp=10,mana=4))",` +
		`"reads":{"self":"(home=Coord(v=5),pos=4294967296,score=0,stats=Stats(hp=10,mana=4))"},` +
		`"ok":true,` +
		`"result":"(home=Coord(v=5),pos=8589934592,score=0,stats=Stats(hp=10,mana=4))",` +
		`"self_after":"Hero(home=Coord(v=5),pos=8589934592,score=0,stats=Stats(hp=10,mana=4))"}]}}`
	testing.expect_value(t, response, expected)
}

// The diff observe compares two retained committed versions and names exactly
// the changed columns with from/to encodings — a pure two-version read.
@(test)
test_introspect_diff_changed_fields :: proc(t: ^testing.T) {
	_, session := fixture_session(t, 2)
	s := session
	response := session_request(&s, `{"id":3,"cmd":"diff","args":{"from":0,"to":1}}`)
	expected :=
		`{"v":1,"id":3,"ok":true,"cmd":"diff","result":{"from":0,"to":1,"tables":[` +
		`{"thing":"Hero","added":[],"removed":[],"changed":[{"id":0,"fields":[` +
		`{"field":"pos","from":"4294967296","to":"8589934592"}]}]}]}}`
	testing.expect_value(t, response, expected)
}

// The replay_behavior observe re-runs the behavior in isolation over its
// captured inputs and verifies the pure re-run reproduces the in-fold result —
// §28 §1's pure-behavior replay lever, with the purity check as a value.
@(test)
test_introspect_replay_behavior_purity :: proc(t: ^testing.T) {
	_, session := fixture_session(t, 2)
	s := session
	response := session_request(&s, `{"id":4,"cmd":"replay_behavior","args":{"tick":0,"behavior":"advance"}}`)
	expected :=
		`{"v":1,"id":4,"ok":true,"cmd":"replay_behavior","result":{"tick":0,"behavior":"advance","instances":[` +
		`{"instance":0,"ok":true,` +
		`"result":"(home=Coord(v=5),pos=4294967296,score=0,stats=Stats(hp=10,mana=4))",` +
		`"refold_matches":true}]}}`
	testing.expect_value(t, response, expected)
}

// golden_pong_session opens an observe session over the EXACT golden pong run
// (the committed acceptance script) — the shared opener for the pong-backed
// observe tests and the digest-pin acceptance.
@(private = "file")
golden_pong_session :: proc(
	t: ^testing.T,
	allocator := context.allocator,
) -> (
	program: ^Program,
	inputs: []Input,
	session: Debug_Session,
) {
	program = new(Program, allocator)
	loaded, err := load_program(GOLDEN_ARTIFACT, allocator)
	testing.expect(t, err == .None, "golden pong artifact must load")
	program^ = loaded
	inputs = golden_session_inputs(allocator)
	session = open_debug_session(program, inputs, NO_SEED, allocator)
	return program, inputs, session
}

// The signals observe surfaces the live dataflow: somewhere in the golden pong
// run the score behavior routes a Goal broadcast, and the observe reports it as
// a typed funpack record string — signals are data (§28 §1).
@(test)
test_introspect_signals_routed_goal :: proc(t: ^testing.T) {
	_, inputs, session := golden_pong_session(t)
	s := session
	found := false
	for tick in 0 ..< len(inputs) {
		b := strings.builder_make()
		strings.write_string(&b, `{"id":9,"cmd":"signals","args":{"tick":`)
		strings.write_int(&b, tick)
		strings.write_string(&b, `}}`)
		response := session_request(&s, strings.to_string(b))
		testing.expect(t, strings.contains(response, `"ok":true`), "signals observe must succeed on every tick")
		if strings.contains(response, `"signal":"Goal"`) {
			testing.expect(
				t,
				strings.contains(response, `Goal(side=Side::`),
				"a routed Goal must render as its typed record encoding",
			)
			found = true
			break
		}
	}
	testing.expect(t, found, "the golden pong run must route at least one Goal signal")
}

// The draw-list observe dumps the §20 render projection of a committed tick —
// pong's paddles/ball Rects and the score Text, re-projected post-hoc.
@(test)
test_introspect_draw_list_dump :: proc(t: ^testing.T) {
	_, _, session := golden_pong_session(t)
	s := session
	response := session_request(&s, `{"id":5,"cmd":"draw_list","args":{"tick":0}}`)
	testing.expect(t, strings.contains(response, `"ok":true`), "draw_list must succeed")
	testing.expect(t, strings.contains(response, "Rect(at=Vec2("), "pong tick 0 must dump Rect commands")
	testing.expect(t, strings.contains(response, "Text(at=Vec2("), "pong tick 0 must dump the score Text")
}

// screenshot is the §28.3 render-crossing TWIN of draw_list — explicitly NOT
// sim-pure (§28 §2). The OUTCOME is build-split: the default define-free build has no
// display, no codec, and the else-arm stub, so the command ROUTES but reports the
// defined "requires live present" boundary refusal (this is what `task test` pins). The
// FUNPACK_LIVE build SERVES the capture HEADLESS — session_capture_frame forces SDL's
// dummy video driver and renders to a CPU surface, so no display is required (this is
// what `task runtime:test-live` pins). The command/branch/tick addressing is identical
// in both; only the present-crossing outcome flips on the build.
@(test)
test_introspect_screenshot_requires_live_present :: proc(t: ^testing.T) {
	_, _, session := golden_pong_session(t)
	s := session
	response := session_request(&s, `{"id":40,"cmd":"screenshot","args":{"tick":0}}`)
	testing.expect(t, strings.contains(response, `"cmd":"screenshot"`), "the envelope must name the screenshot command")
	when #config(FUNPACK_LIVE, false) {
		// The FUNPACK_LIVE build serves the offscreen capture with no display: the
		// command succeeds and returns the qoi-format pixel payload (the present pass
		// ran on the dummy driver's CPU surface).
		testing.expect(t, strings.contains(response, `"ok":true`), "FUNPACK_LIVE screenshot serves headless via the dummy driver")
		testing.expect(t, strings.contains(response, `"format":"qoi"`), "the served capture carries the qoi pixel payload")
	} else {
		// The default define-free build refuses at the present boundary — no codec, no
		// display, the no-display stub — and the refusal points at the build that serves it.
		testing.expect(t, strings.contains(response, `"ok":false`), "headless default screenshot must refuse — no codec, no display")
		testing.expect(
			t,
			strings.contains(response, "render/present boundary"),
			"the refusal must name the render/present boundary it cannot cross headless",
		)
		testing.expect(
			t,
			strings.contains(response, "FUNPACK_LIVE"),
			"the refusal must point at the FUNPACK_LIVE build that serves the capture",
		)
	}
}

// THE WARRANTY DISTINCTION (§28 §2): draw_list is the sim-pure draw-list dump that
// NEVER crosses the render/present boundary; screenshot is its render-crossing twin and
// is NOT sim-pure. Over ONE session at the SAME tick, draw_list ALWAYS serves headless
// with the deterministic draw-list (it never touches present). screenshot ALWAYS crosses
// present — the distinction the warranty rests on — and that crossing's outcome is
// build-split: the default define-free build refuses it (no codec, no display), while the
// FUNPACK_LIVE build serves it from the offscreen CPU render path with no display. Either
// way screenshot is the render-crossing, NOT-sim-pure twin; only whether the crossing
// completes depends on whether the present codec is compiled in.
@(test)
test_introspect_draw_list_screenshot_distinction :: proc(t: ^testing.T) {
	_, _, session := golden_pong_session(t)
	s := session

	draw_resp := session_request(&s, `{"id":41,"cmd":"draw_list","args":{"tick":0}}`)
	testing.expect(t, strings.contains(draw_resp, `"ok":true`), "sim-pure draw_list serves headless")
	testing.expect(t, strings.contains(draw_resp, "Rect(at=Vec2("), "draw_list dumps the deterministic draw-list")

	shot_resp := session_request(&s, `{"id":42,"cmd":"screenshot","args":{"tick":0}}`)
	when #config(FUNPACK_LIVE, false) {
		// The render-crossing twin completes headless under FUNPACK_LIVE: the present
		// codec is compiled in and runs on the dummy driver's CPU surface. The distinction
		// stands — draw_list never crossed present; screenshot did, and returns pixels.
		testing.expect(t, strings.contains(shot_resp, `"ok":true`), "FUNPACK_LIVE screenshot crosses present and serves headless")
		testing.expect(t, strings.contains(shot_resp, `"format":"qoi"`), "the crossed-present capture carries pixels")
	} else {
		// The default build's present codec is compiled out, so the render-crossing twin
		// refuses — the visible split that the warranty rests on in the deterministic suite.
		testing.expect(
			t,
			strings.contains(shot_resp, `"ok":false`),
			"the render-crossing screenshot refuses in the codec-free default build — it is NOT sim-pure",
		)
	}
}

// screenshot validates its args through the SAME observe-addressing path draw_list
// uses (tick required, branch resolved, tick range checked) — every reject is a
// well-formed refusal envelope, never a crash and never a partial capture.
@(test)
test_introspect_screenshot_arg_refusals :: proc(t: ^testing.T) {
	_, _, session := golden_pong_session(t)
	s := session

	cases := [?]struct {
		request:  string,
		fragment: string,
	} {
		{`{"id":43,"cmd":"screenshot"}`, `missing args.tick`},
		{`{"id":44,"cmd":"screenshot","args":{"tick":99999}}`, `tick out of range`},
		{`{"id":45,"cmd":"screenshot","args":{"tick":-2}}`, `tick out of range`},
		{`{"id":46,"cmd":"screenshot","args":{"tick":0,"branch":"branch"}}`, `unknown branch`},
	}
	for entry in cases {
		response := session_request(&s, entry.request)
		testing.expect(t, strings.contains(response, `"ok":false`), "a refused screenshot must answer ok:false")
		testing.expect(t, strings.contains(response, entry.fragment), entry.fragment)
	}
}

// THE include_drawlist TOGGLE ON THE SERVED PATH (§20 §5, §28 §3). screenshot crosses
// the render/present boundary and serves the impure pixel capture; `include_drawlist:true`
// makes the DETERMINISTIC §20 draw-list ride along in the SAME envelope as data — the
// same render_draw_cmd_text encoding draw_list emits, so the served `commands` carry the
// `Rect(at=Vec2(` literal alongside the qoi pixels. Both surfaces cross in one response:
// the impure pixels AND the deterministic draw-list. Omitting the flag is the lean
// default — pixels only, no draw-list data. This pins the toggle on the SERVED path,
// which exists only under FUNPACK_LIVE (the codec-free default build refuses the crossing
// before it can carry either surface), so the assertions are gated like the live-branch
// arms of the sibling screenshot tests.
@(test)
test_introspect_screenshot_include_drawlist_served :: proc(t: ^testing.T) {
	_, _, session := golden_pong_session(t)
	s := session

	with_drawlist := session_request(&s, `{"id":47,"cmd":"screenshot","args":{"tick":0,"include_drawlist":true}}`)
	pixels_only := session_request(&s, `{"id":48,"cmd":"screenshot","args":{"tick":0}}`)

	when #config(FUNPACK_LIVE, false) {
		// include_drawlist:true → BOTH surfaces in one envelope: the qoi pixels (the
		// impure present crossing) and the deterministic draw-list data (the Rect literal
		// the draw_list dump emits via the same render_draw_cmd_text encoding).
		testing.expect(t, strings.contains(with_drawlist, `"ok":true`), "the served include_drawlist screenshot succeeds under FUNPACK_LIVE")
		testing.expect(t, strings.contains(with_drawlist, `"format":"qoi"`), "include_drawlist carries the impure qoi pixel payload")
		testing.expect(
			t,
			strings.contains(with_drawlist, "Rect(at=Vec2("),
			"include_drawlist appends the deterministic draw-list as data — the same Rect encoding draw_list emits",
		)

		// No flag → the lean default: pixels cross, the draw-list does NOT ride along.
		testing.expect(t, strings.contains(pixels_only, `"ok":true`), "the plain served screenshot succeeds under FUNPACK_LIVE")
		testing.expect(t, strings.contains(pixels_only, `"format":"qoi"`), "the plain screenshot carries the qoi pixels")
		testing.expect(
			t,
			!strings.contains(pixels_only, "Rect(at=Vec2("),
			"the lean default screenshot carries pixels only — no draw-list data without the flag",
		)
	} else {
		// The codec-free default build refuses the crossing before it can carry either
		// surface, so neither response reaches the served shape this test pins.
		testing.expect(t, strings.contains(with_drawlist, `"ok":false`), "the codec-free default build refuses the crossing — no served draw-list")
		testing.expect(t, strings.contains(pixels_only, `"ok":false`), "the codec-free default build refuses the lean crossing too")
	}
}

// reference_unobserved_capture folds the golden run with NO session and NO
// observe tap — the production seam verbatim — capturing per-tick digests and
// the final committed version. It is the ground truth the digest pin compares
// the observed session against.
@(private = "file")
reference_unobserved_capture :: proc(
	program: ^Program,
	inputs: []Input,
	allocator := context.allocator,
) -> (
	capture: Frame_Capture,
	final: World_Version,
) {
	world := new_world(program^, allocator)
	version := run_startup(program, initial_version(world, allocator), allocator)
	tick_hz := program.entrypoint.tick_hz
	per_tick := make([dynamic]Frame_Digest, 0, len(inputs), allocator)
	for snapshot, i in inputs {
		time := time_resource_at(tick_hz, i, allocator)
		version = step_tick(program, version, snapshot, time, allocator)
		draw := render_version(program, version, snapshot, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator), version
}

// THE STORY ACCEPTANCE — observe is non-perturbing, proven with a digest pin:
// an observe session that serves the WHOLE observe battery (pipeline, signals,
// trace, diff, replay_behavior, draw_list) over the golden pong run digests its
// canonical chain bit-identical to a run nobody observed — per-tick digests,
// session digest, and the final committed world (world_versions_equal). §28 §2:
// observation can never change behavior — no heisenbugs.
@(test)
test_introspect_observe_non_perturbing_digest_pin :: proc(t: ^testing.T) {
	program, inputs, session := golden_pong_session(t)
	s := session
	baseline, baseline_final := reference_unobserved_capture(program, inputs)

	battery := [?]string {
		`{"id":1,"cmd":"pipeline"}`,
		`{"id":2,"cmd":"signals","args":{"tick":0}}`,
		`{"id":3,"cmd":"signals","args":{"tick":58}}`,
		`{"id":4,"cmd":"trace","args":{"tick":3,"behavior":"paddle_move"}}`,
		`{"id":5,"cmd":"trace","args":{"tick":58,"behavior":"ball_move"}}`,
		`{"id":6,"cmd":"diff","args":{"from":-1,"to":0}}`,
		`{"id":7,"cmd":"diff","args":{"from":0,"to":599}}`,
		`{"id":8,"cmd":"replay_behavior","args":{"tick":2,"behavior":"ball_move"}}`,
		`{"id":9,"cmd":"draw_list","args":{"tick":0}}`,
		`{"id":10,"cmd":"draw_list","args":{"tick":599}}`,
	}
	for request in battery {
		response := session_request(&s, request)
		testing.expect(t, strings.contains(response, `"ok":true`), "every observe in the battery must succeed")
	}

	// screenshot rides the SAME non-perturbing battery: it re-projects the committed
	// tick to a draw-list (render_version — a pure post-commit projection) before it
	// crosses into present, so whether the present crossing REFUSES (codec-free default
	// build) or SERVES the pixels (FUNPACK_LIVE, offscreen CPU render headless), the
	// re-projection writes nothing to the canonical chain. The per-request outcome is
	// build-split; the digest pin below proves it left no trace in EITHER build — the
	// warranty that screenshot, though not sim-pure, is non-perturbing.
	screenshots := [?]string {
		`{"id":20,"cmd":"screenshot","args":{"tick":0}}`,
		`{"id":21,"cmd":"screenshot","args":{"tick":599,"include_drawlist":true}}`,
	}
	for request in screenshots {
		response := session_request(&s, request)
		when #config(FUNPACK_LIVE, false) {
			testing.expect(t, strings.contains(response, `"ok":true`), "FUNPACK_LIVE screenshot serves headless but must not perturb")
		} else {
			testing.expect(t, strings.contains(response, `"ok":false`), "codec-free screenshot refuses but must not perturb")
		}
	}

	observed := session_capture(&s)
	testing.expect_value(t, len(observed.per_tick), len(baseline.per_tick))
	for frame, i in observed.per_tick {
		testing.expect_value(t, frame.tick, baseline.per_tick[i].tick)
		testing.expect_value(t, frame.digest, baseline.per_tick[i].digest)
	}
	testing.expect_value(t, observed.session, baseline.session)
	testing.expect(
		t,
		world_versions_equal(s.versions[len(s.versions) - 1], baseline_final),
		"the observed session's final committed world must equal the unobserved run's",
	)
}

// Every malformed or unservable request is refused with a well-formed
// `"ok":false` envelope — the fold never panics on wire input, and the §28 §2
// exact-match version gate refuses a foreign protocol version.
@(test)
test_introspect_request_refusals :: proc(t: ^testing.T) {
	_, session := fixture_session(t, 2)
	s := session

	cases := [?]struct {
		request:  string,
		fragment: string,
	} {
		{`not json at all`, `"ok":false`},
		{`{"id":11}`, `missing cmd`},
		{`{"id":12,"cmd":"warp"}`, `unknown command`},
		{`{"id":13,"cmd":"signals"}`, `missing args.tick`},
		{`{"id":14,"cmd":"signals","args":{"tick":9999}}`, `tick out of range`},
		{`{"id":15,"cmd":"trace","args":{"tick":0,"behavior":"nope"}}`, `unknown behavior`},
		{`{"v":2,"id":16,"cmd":"pipeline"}`, `protocol version mismatch`},
		{`{"id":17,"cmd":"diff","args":{"from":-2,"to":0}}`, `tick out of range`},
	}
	for entry in cases {
		response := session_request(&s, entry.request)
		testing.expect(t, strings.contains(response, `"ok":false`), "a refused request must answer ok:false")
		testing.expect(t, strings.contains(response, entry.fragment), entry.fragment)
	}
}

// test_draw_list_dump_formats_color_named_and_rgb pins the §28 draw-list color
// projection (the Color::Rgb introspect format): render_draw_cmd_text dumps a NAMED
// color as `Color::<Member>` (the existing line shape, preserved after Draw_Color
// stopped being a bare enum %v could print directly) and a Color::Rgb as
// `Color::Rgb(<r>,<g>,<b>)` with the RAW Q32.32 channel ints — the SAME `i64(fixed)`
// convention the Vec2 `x=%d` lanes use, so the string is deterministic (no float)
// and byte-stable across machines. This is the line `inspect_draw_list` shows.
@(test)
test_draw_list_dump_formats_color_named_and_rgb :: proc(t: ^testing.T) {
	at := Vec2{to_fixed(8), to_fixed(60)}
	size := Vec2{to_fixed(4), to_fixed(16)}

	// A named Gray rect dumps `color=Color::Gray` — unchanged from the bare-enum era.
	named_b := strings.builder_make(context.temp_allocator)
	render_draw_cmd_text(&named_b, Draw_Rect{at = at, size = size, color = named_color(.Gray)})
	named_out := strings.to_string(named_b)
	testing.expect(t, strings.contains(named_out, "color=Color::Gray"), named_out)

	// A Color::Rgb rect dumps `color=Color::Rgb(<r>,<g>,<b>)` with raw Q32.32 ints.
	// r=1.0 (FIXED_ONE), g=0.5 (half), b=0.0 — so the channels render as their raw
	// bits: FIXED_ONE = 1<<32 = 4294967296, half = 1<<31 = 2147483648, 0.
	half := fixed_div(FIXED_ONE, to_fixed(2))
	rgb_b := strings.builder_make(context.temp_allocator)
	render_draw_cmd_text(&rgb_b, Draw_Rect{at = at, size = size, color = rgb_color(FIXED_ONE, half, Fixed(0))})
	rgb_out := strings.to_string(rgb_b)
	testing.expect(t, strings.contains(rgb_out, "color=Color::Rgb(4294967296,2147483648,0)"), rgb_out)
}
