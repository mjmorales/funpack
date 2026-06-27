package funpack_runtime

import "core:strings"
import "core:testing"

@(private = "file")
INTROSPECT_FIXTURE :: "funpack-artifact 19\n" +
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

@(test)
test_introspect_trace_behavior_transition :: proc(t: ^testing.T) {
	_, session := fixture_session(t, 3)
	s := session
	response := session_request(&s, `{"id":7,"cmd":"trace","args":{"tick":1,"behavior":"advance"}}`)
	expected :=
		`{"v":1,"id":7,"ok":true,"cmd":"trace","result":{"tick":1,"behavior":"advance","steps":[` +
		`{"ordinal":0,"instance":0,` +
		`"self_before":"Hero(home=Coord(v=5),pos=1.0,score=0,stats=Stats(hp=10,mana=4))",` +
		`"reads":{"self":"(home=Coord(v=5),pos=1.0,score=0,stats=Stats(hp=10,mana=4))"},` +
		`"ok":true,` +
		`"result":"(home=Coord(v=5),pos=2.0,score=0,stats=Stats(hp=10,mana=4))",` +
		`"self_after":"Hero(home=Coord(v=5),pos=2.0,score=0,stats=Stats(hp=10,mana=4))"}]}}`
	testing.expect_value(t, response, expected)
}

@(test)
test_introspect_diff_changed_fields :: proc(t: ^testing.T) {
	_, session := fixture_session(t, 2)
	s := session
	response := session_request(&s, `{"id":3,"cmd":"diff","args":{"from":0,"to":1}}`)
	expected :=
		`{"v":1,"id":3,"ok":true,"cmd":"diff","result":{"from":0,"to":1,"tables":[` +
		`{"thing":"Hero","added":[],"removed":[],"changed":[{"id":0,"fields":[` +
		`{"field":"pos","from":"1.0","to":"2.0"}]}]}]}}`
	testing.expect_value(t, response, expected)
}

@(test)
test_introspect_replay_behavior_purity :: proc(t: ^testing.T) {
	_, session := fixture_session(t, 2)
	s := session
	response := session_request(&s, `{"id":4,"cmd":"replay_behavior","args":{"tick":0,"behavior":"advance"}}`)
	expected :=
		`{"v":1,"id":4,"ok":true,"cmd":"replay_behavior","result":{"tick":0,"behavior":"advance","instances":[` +
		`{"instance":0,"ok":true,` +
		`"result":"(home=Coord(v=5),pos=1.0,score=0,stats=Stats(hp=10,mana=4))",` +
		`"refold_matches":true}]}}`
	testing.expect_value(t, response, expected)
}

@(test)
test_introspect_state_lists_committed_instance :: proc(t: ^testing.T) {
	_, session := fixture_session(t, 2)
	s := session
	response := session_request(&s, `{"id":5,"cmd":"state","args":{"thing":"Hero","tick":1}}`)
	expected :=
		`{"v":1,"id":5,"ok":true,"cmd":"state","result":{"tick":1,"thing":"Hero","instances":[` +
		`{"id":0,"fields":{"home":"Coord(v=5)","pos":"2.0","score":"0","stats":"Stats(hp=10,mana=4)"}}]}}`
	testing.expect_value(t, response, expected)
}

@(test)
test_introspect_state_default_tick_and_unknown_thing :: proc(t: ^testing.T) {
	_, session := fixture_session(t, 3)
	s := session
	head := session_request(&s, `{"id":6,"cmd":"state","args":{"thing":"Hero"}}`)
	testing.expect(t, strings.contains(head, `"ok":true`), head)
	testing.expect(t, strings.contains(head, `"tick":2`), "an omitted tick reads the lineage head")
	testing.expect(t, strings.contains(head, `"pos":"3.0"`), head)
	unknown := session_request(&s, `{"id":7,"cmd":"state","args":{"thing":"Nope"}}`)
	testing.expect(t, strings.contains(unknown, `"ok":false`), "an unknown thing must refuse")
	testing.expect(t, strings.contains(unknown, "unknown thing"), unknown)
}

@(test)
test_introspect_state_instance_filter :: proc(t: ^testing.T) {
	_, _, session := golden_pong_session(t)
	s := session
	all := session_request(&s, `{"id":8,"cmd":"state","args":{"thing":"Paddle","tick":0}}`)
	testing.expect(t, strings.contains(all, `"ok":true`), all)
	testing.expect(t, strings.contains(all, `"id":0`), "both paddles listed")
	testing.expect(t, strings.contains(all, `"id":1`), "both paddles listed")
	one := session_request(&s, `{"id":9,"cmd":"state","args":{"thing":"Paddle","tick":0,"instance":1}}`)
	testing.expect(t, strings.contains(one, `"id":1`), one)
	testing.expect(t, !strings.contains(one, `"id":0`), "the instance filter must exclude the other paddle")
}

@(private = "file")
SEEDLESS_STARTUP_ARTIFACT := #load("testdata/seedless_startup_spawn.artifact", string)

@(test)
test_introspect_seedless_programmatic_startup_populates :: proc(t: ^testing.T) {
	program := new(Program, context.allocator)
	loaded, err := load_program(SEEDLESS_STARTUP_ARTIFACT, context.allocator)
	testing.expect(t, err == .None, "the seedless programmatic-startup artifact must load")
	program^ = loaded

	ticks :: 4
	inputs := make([]Input, ticks, context.allocator)
	for i in 0 ..< ticks {
		inputs[i] = empty()
	}
	session := open_debug_session(program, inputs, NO_SEED, context.allocator)
	s := session
	testing.expect(t, !s.seed.has_seed, "the game is seedless (no Rng resource)")

	status := session_request(&s, `{"id":0,"cmd":"status"}`)
	testing.expect(t, strings.contains(status, `"seeded":false`), status)
	testing.expect(t, strings.contains(status, `"uses_rng":false`), status)

	startup := session_request(&s, `{"id":1,"cmd":"state","args":{"thing":"Mote","tick":-1}}`)
	testing.expect(t, strings.contains(startup, `"ok":true`), startup)
	for id in 0 ..< 4 {
		testing.expectf(t, strings.contains(startup, sbprint_id(id)), "Mote#%d must be spawned at startup, got: %s", id, startup)
	}

	tick2 := session_request(&s, `{"id":2,"cmd":"state","args":{"thing":"Mote","tick":2}}`)
	testing.expect(t, strings.contains(tick2, `"ok":true`), tick2)
	for id in 0 ..< 4 {
		testing.expectf(t, strings.contains(tick2, sbprint_id(id)), "Mote#%d must persist at a folded tick, got: %s", id, tick2)
	}

	world := new_world(program^, context.allocator)
	base := initial_version(world, context.allocator)
	reference := run_startup(program, base, context.allocator)
	testing.expect(
		t,
		world_versions_equal(s.startup, reference),
		"the session's folded startup must equal a plain run_startup fold (determinism warranty)",
	)
}

@(private = "file")
sbprint_id :: proc(id: int) -> string {
	b := strings.builder_make(context.allocator)
	strings.write_string(&b, `"id":`)
	strings.write_int(&b, id)
	return strings.to_string(b)
}

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

@(test)
test_introspect_trace_render_behavior_captured :: proc(t: ^testing.T) {
	_, _, session := golden_pong_session(t)
	s := session
	response := session_request(&s, `{"id":7,"cmd":"trace","args":{"tick":1,"behavior":"draw_ball"}}`)
	testing.expect(t, strings.contains(response, `"ok":true`), response)
	testing.expect(t, strings.contains(response, `"behavior":"draw_ball"`), response)
	testing.expect(
		t,
		!strings.contains(response, `"steps":[]`),
		"a render behavior that ran must trace a non-empty step list",
	)
	testing.expect(t, strings.contains(response, `"instance":0`), "the single Ball instance must be traced")
	testing.expect(t, strings.contains(response, "Rect("), response)
}

@(test)
test_introspect_trace_audio_stage_marker :: proc(t: ^testing.T) {
	program := new(Program, context.allocator)
	loaded, err := load_program(KROGNID_ARTIFACT, context.allocator)
	testing.expect(t, err == .None, "krognid artifact must load")
	program^ = loaded
	inputs := make([]Input, 2, context.allocator)
	for i in 0 ..< len(inputs) {
		inputs[i] = empty()
	}
	session := open_debug_session(program, inputs, NO_SEED, context.allocator)
	s := session
	response := session_request(&s, `{"id":7,"cmd":"trace","args":{"tick":0,"behavior":"locomotion"}}`)
	testing.expect(t, strings.contains(response, `"ok":true`), response)
	testing.expect(t, strings.contains(response, `"stage":"audio"`), response)
	testing.expect(t, strings.contains(response, `"steps":[]`), "an unsupported stage carries an empty step list")
	testing.expect(t, strings.contains(response, `"note":`), "the marker must explain why the stage is not folded")
}

@(test)
test_introspect_trace_startup_stage_marker :: proc(t: ^testing.T) {
	_, _, session := golden_pong_session(t)
	s := session
	response := session_request(&s, `{"id":7,"cmd":"trace","args":{"tick":0,"behavior":"setup"}}`)
	testing.expect(t, strings.contains(response, `"ok":true`), response)
	testing.expect(t, strings.contains(response, `"stage":"startup"`), response)
	testing.expect(t, strings.contains(response, `"steps":[]`), "an unsupported stage carries an empty step list")
	testing.expect(
		t,
		strings.contains(response, `before tick 0`),
		"the startup marker note must explain it runs before tick 0, not the generic unknown-behavior refusal",
	)
	testing.expect(
		t,
		!strings.contains(response, `unknown behavior`),
		"a behavior inspect_pipeline lists must never be denied as unknown",
	)
	unknown := session_request(&s, `{"id":8,"cmd":"trace","args":{"tick":0,"behavior":"nope"}}`)
	testing.expect(t, strings.contains(unknown, `"ok":false`), unknown)
	testing.expect(t, strings.contains(unknown, `unknown behavior`), unknown)
}

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

@(test)
test_draw_list_keeps_out_of_bounds_rect :: proc(t: ^testing.T) {
	_, _, session := golden_pong_session(t)
	s := session
	set := session_request(
		&s,
		`{"id":1,"cmd":"set","args":{"thing":"Ball","instance":0,"field":"pos","value":"Vec2(x=-1.0,y=60.0)"}}`,
	)
	testing.expect(t, strings.contains(set, `"ok":true`), set)

	tip := branch_tip_tick(&s)
	b := strings.builder_make()
	strings.write_string(&b, `{"id":2,"cmd":"draw_list","args":{"branch":"branch","tick":`)
	strings.write_int(&b, tip)
	strings.write_string(&b, `}}`)
	response := session_request(&s, strings.to_string(b))
	testing.expect(t, strings.contains(response, `"ok":true`), response)
	testing.expect(
		t,
		strings.contains(response, "Rect(at=Vec2(x=-1.0,y=60.0)"),
		"the out-of-bounds Ball rect must survive the draw-list projection (no culling)",
	)
}

@(test)
test_introspect_draw_list_overlay :: proc(t: ^testing.T) {
	_, _, session := golden_pong_session(t)
	s := session
	plain := session_request(&s, `{"id":5,"cmd":"draw_list","args":{"tick":0}}`)
	testing.expect(t, !strings.contains(plain, "Color::Magenta"), "no overlay without the flag")
	over := session_request(&s, `{"id":6,"cmd":"draw_list","args":{"tick":0,"overlay":true}}`)
	testing.expect(t, strings.contains(over, `"ok":true`), over)
	testing.expect(t, strings.contains(over, "Color::Magenta"), "overlay:true must add the collision-extent commands")
	testing.expect(t, strings.contains(over, "Text(at=Vec2("), "the overlay rides on top of, not instead of, the real draw-list")
}

@(test)
test_introspect_draw_list_dump :: proc(t: ^testing.T) {
	_, _, session := golden_pong_session(t)
	s := session
	response := session_request(&s, `{"id":5,"cmd":"draw_list","args":{"tick":0}}`)
	testing.expect(t, strings.contains(response, `"ok":true`), "draw_list must succeed")
	testing.expect(t, strings.contains(response, "Rect(at=Vec2("), "pong tick 0 must dump Rect commands")
	testing.expect(t, strings.contains(response, "Text(at=Vec2("), "pong tick 0 must dump the score Text")
}

@(test)
test_introspect_screenshot_requires_live_present :: proc(t: ^testing.T) {
	_, _, session := golden_pong_session(t)
	s := session
	response := session_request(&s, `{"id":40,"cmd":"screenshot","args":{"tick":0}}`)
	testing.expect(t, strings.contains(response, `"cmd":"screenshot"`), "the envelope must name the screenshot command")
	when #config(FUNPACK_LIVE, false) {
		testing.expect(t, strings.contains(response, `"ok":true`), "FUNPACK_LIVE screenshot serves headless via the dummy driver")
		testing.expect(t, strings.contains(response, `"format":"qoi"`), "the served capture carries the qoi pixel payload")
	} else {
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

@(test)
test_introspect_draw_list_screenshot_distinction :: proc(t: ^testing.T) {
	_, _, session := golden_pong_session(t)
	s := session

	draw_resp := session_request(&s, `{"id":41,"cmd":"draw_list","args":{"tick":0}}`)
	testing.expect(t, strings.contains(draw_resp, `"ok":true`), "sim-pure draw_list serves headless")
	testing.expect(t, strings.contains(draw_resp, "Rect(at=Vec2("), "draw_list dumps the deterministic draw-list")

	shot_resp := session_request(&s, `{"id":42,"cmd":"screenshot","args":{"tick":0}}`)
	when #config(FUNPACK_LIVE, false) {
		testing.expect(t, strings.contains(shot_resp, `"ok":true`), "FUNPACK_LIVE screenshot crosses present and serves headless")
		testing.expect(t, strings.contains(shot_resp, `"format":"qoi"`), "the crossed-present capture carries pixels")
	} else {
		testing.expect(
			t,
			strings.contains(shot_resp, `"ok":false`),
			"the render-crossing screenshot refuses in the codec-free default build — it is NOT sim-pure",
		)
	}
}

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

@(test)
test_introspect_screenshot_include_drawlist_served :: proc(t: ^testing.T) {
	_, _, session := golden_pong_session(t)
	s := session

	with_drawlist := session_request(&s, `{"id":47,"cmd":"screenshot","args":{"tick":0,"include_drawlist":true}}`)
	pixels_only := session_request(&s, `{"id":48,"cmd":"screenshot","args":{"tick":0}}`)

	when #config(FUNPACK_LIVE, false) {
		testing.expect(t, strings.contains(with_drawlist, `"ok":true`), "the served include_drawlist screenshot succeeds under FUNPACK_LIVE")
		testing.expect(t, strings.contains(with_drawlist, `"format":"qoi"`), "include_drawlist carries the impure qoi pixel payload")
		testing.expect(
			t,
			strings.contains(with_drawlist, "Rect(at=Vec2("),
			"include_drawlist appends the deterministic draw-list as data — the same Rect encoding draw_list emits",
		)

		testing.expect(t, strings.contains(pixels_only, `"ok":true`), "the plain served screenshot succeeds under FUNPACK_LIVE")
		testing.expect(t, strings.contains(pixels_only, `"format":"qoi"`), "the plain screenshot carries the qoi pixels")
		testing.expect(
			t,
			!strings.contains(pixels_only, "Rect(at=Vec2("),
			"the lean default screenshot carries pixels only — no draw-list data without the flag",
		)
	} else {
		testing.expect(t, strings.contains(with_drawlist, `"ok":false`), "the codec-free default build refuses the crossing — no served draw-list")
		testing.expect(t, strings.contains(pixels_only, `"ok":false`), "the codec-free default build refuses the lean crossing too")
	}
}

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

@(test)
test_draw_list_dump_formats_color_named_and_rgb :: proc(t: ^testing.T) {
	at := Vec2{to_fixed(8), to_fixed(60)}
	size := Vec2{to_fixed(4), to_fixed(16)}

	named_b := strings.builder_make(context.temp_allocator)
	render_draw_cmd_text(&named_b, Draw_Rect{at = at, size = size, color = named_color(.Gray)})
	named_out := strings.to_string(named_b)
	testing.expect(t, strings.contains(named_out, "color=Color::Gray"), named_out)

	half := fixed_div(FIXED_ONE, to_fixed(2))
	rgb_b := strings.builder_make(context.temp_allocator)
	render_draw_cmd_text(&rgb_b, Draw_Rect{at = at, size = size, color = rgb_color(FIXED_ONE, half, Fixed(0))})
	rgb_out := strings.to_string(rgb_b)
	testing.expect(t, strings.contains(rgb_out, "color=Color::Rgb(1.0,0.5,0.0)"), rgb_out)
}
