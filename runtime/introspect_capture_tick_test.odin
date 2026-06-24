// §28 §5 capture → test acceptance for `capture_tick` — the whole-tick-twin
// guard. capture_tick reads a recorded tick's committed pre-state (version
// tick-1; tick 0's pre is the post-startup version) and post-state (version
// tick) of a thing and renders a funpack `test` asserting the hand-rolled twin
// reproduces the LIVE Id-ordered schedule: `assert twin([pre]) == [post]`. The
// post rows are the live fold's committed output, so a twin that diverges (e.g.
// a simultaneous map over the pre-snapshot) fails the assert — the mechanical
// guard for the friction the determinism contract otherwise only warns about.
//
// The fixture is a synthetic two-Counter program whose `bump` behavior rewrites
// every Counter's mark to 7 in one stage, plus three candidate twins: a `[T]`
// form, a `View[T]` form, and a malformed `Int->Int` form (the refusal). The
// twin BODY is never executed by capture_tick (it only reads the signature to
// shape the rendered call), so a trivial `return xs` body suffices.
package funpack_runtime

import "core:testing"

// tk_fields / tk_children heap-allocate a hand-built node's slices from the test
// arena so a fixture node escapes its constructing frame (the interp_test mold).
@(private = "file")
tk_fields :: proc(tokens: ..string) -> []string {
	out := make([]string, len(tokens), context.temp_allocator)
	copy(out, tokens)
	return out
}

@(private = "file")
tk_children :: proc(nodes: ..Node) -> []Node {
	out := make([]Node, len(nodes), context.temp_allocator)
	copy(out, nodes)
	return out
}

// tk_return wraps a value subtree in a `.Return` statement body of one node.
@(private = "file")
tk_return :: proc(value: Node, allocator := context.allocator) -> []Node {
	body := make([]Node, 1, allocator)
	body[0] = Node{kind = .Return, children = tk_children(value)}
	return body
}

// counter_tick_program builds the synthetic whole-tick fixture: a thing
// `Counter { mark: Int }`, a `bump` stage rewriting every mark to 7, two
// Counters seeded mark 0, and three candidate twins (the [T] form `mark_twin`,
// the View[T] form `view_twin`, the malformed `wrong_twin(x: Int) -> Int`).
@(private = "file")
counter_tick_program :: proc(allocator := context.allocator) -> ^Program {
	program := new(Program, allocator)

	cfields := make([]Field_Decl, 1, allocator)
	cfields[0] = Field_Decl{name = "mark", type = "Int"}
	things := make([]Thing_Decl, 1, allocator)
	things[0] = Thing_Decl{name = "Counter", fields = cfields}

	// behavior bump on Counter: return Counter{mark: 7}
	mark_rf := Node {
		kind     = .Recfield,
		fields   = tk_fields("mark"),
		children = tk_children(Node{kind = .Int, fields = tk_fields("7")}),
	}
	rec := Node{kind = .Record, fields = tk_fields("Counter"), children = tk_children(mark_rf)}
	bparams := make([]Param_Decl, 1, allocator)
	bparams[0] = Param_Decl{name = "self", type = "Counter"}
	bemits := make([]string, 1, allocator)
	bemits[0] = "Counter"
	behaviors := make([]Behavior_Decl, 1, allocator)
	behaviors[0] = Behavior_Decl {
		name     = "bump",
		on_thing = "Counter",
		stage    = "s1",
		params   = bparams,
		emits    = bemits,
		body     = tk_return(rec, allocator),
	}

	// three candidate twins; bodies (`return xs` / `return 0`) never run.
	xs := Node{kind = .Name, fields = tk_fields("xs")}
	functions := make([]Function_Decl, 3, allocator)
	list_param := make([]Param_Decl, 1, allocator)
	list_param[0] = Param_Decl{name = "xs", type = "[Counter]"}
	functions[0] = Function_Decl {
		name        = "mark_twin",
		kind        = .Fn,
		params      = list_param,
		return_type = "[Counter]",
		body        = tk_return(xs, allocator),
	}
	view_param := make([]Param_Decl, 1, allocator)
	view_param[0] = Param_Decl{name = "xs", type = "View[Counter]"}
	functions[1] = Function_Decl {
		name        = "view_twin",
		kind        = .Fn,
		params      = view_param,
		return_type = "[Counter]",
		body        = tk_return(xs, allocator),
	}
	int_param := make([]Param_Decl, 1, allocator)
	int_param[0] = Param_Decl{name = "x", type = "Int"}
	functions[2] = Function_Decl {
		name        = "wrong_twin",
		kind        = .Fn,
		params      = int_param,
		return_type = "Int",
		body        = tk_return(Node{kind = .Int, fields = tk_fields("0")}, allocator),
	}

	pipeline := make([]Pipeline_Step, 1, allocator)
	pipeline[0] = Pipeline_Step{ordinal = 0, stage = "s1", behavior = "bump"}

	setup := make([]Spawn_Command, 2, allocator)
	for i in 0 ..< 2 {
		sf := make([]Spawn_Field, 1, allocator)
		sf[0] = Spawn_Field{name = "mark", kind = .Int, int_val = 0}
		setup[i] = Spawn_Command{thing = "Counter", fields = sf}
	}

	program^ = Program {
		things     = things,
		functions  = functions,
		behaviors  = behaviors,
		pipeline   = pipeline,
		setup      = setup,
		entrypoint = Entrypoint{tick_hz = 60},
	}
	return program
}

// counter_tick_session runs the fixture for one tick: startup seeds two
// Counters at mark 0, tick 0's `bump` rewrites both to 7 — so capture_tick at
// tick 0 reads pre=[0,0] (post-startup) and post=[7,7] (committed).
@(private = "file")
counter_tick_session :: proc(allocator := context.allocator) -> Debug_Session {
	program := counter_tick_program(allocator)
	inputs := make([]Input, 1, allocator)
	inputs[0] = empty()
	return open_debug_session(program, inputs, NO_SEED, allocator)
}

// THE ACCEPTANCE GOLDEN — the [T]-twin whole-tick capture, pinned byte-for-byte:
// capture_tick renders `assert mark_twin([pre]) == [post]`, where pre is the
// post-startup [0,0] and post is the live committed [7,7]. A twin that modeled
// the tick as a simultaneous map over the pre-snapshot would NOT reproduce [7,7]
// from a self-update fold, so the assert is the guard.
@(test)
test_capture_tick_pins_whole_tick_twin :: proc(t: ^testing.T) {
	s := counter_tick_session()
	response := session_request(&s, `{"id":1,"cmd":"capture_tick","args":{"tick":0,"thing":"Counter","twin":"mark_twin"}}`)
	expected :=
		`{"v":1,"id":1,"ok":true,"cmd":"capture_tick","result":{"tick":0,"thing":"Counter","twin":"mark_twin",` +
		`"test":"@doc(\"Captured by capture_tick: mark_twin vs the live schedule for Counter over tick 0 of a recorded session.\")\n` +
		`test \"captured tick 0 Counter twin mark_twin\" {\n` +
		`  assert mark_twin([Counter{mark: 0}, Counter{mark: 0}]) == [Counter{mark: 7}, Counter{mark: 7}]\n}\n"}}`
	testing.expect_value(t, response, expected)
}

// A View[T] twin wraps the pre rows in View.of(…) — the param-shape projection:
// the LHS reads `view_twin(View.of([pre]))`, the expected RHS stays the `[post]`
// list the twin returns.
@(test)
test_capture_tick_view_twin_wraps_in_view_of :: proc(t: ^testing.T) {
	s := counter_tick_session()
	response := session_request(&s, `{"id":2,"cmd":"capture_tick","args":{"tick":0,"thing":"Counter","twin":"view_twin"}}`)
	expected :=
		`{"v":1,"id":2,"ok":true,"cmd":"capture_tick","result":{"tick":0,"thing":"Counter","twin":"view_twin",` +
		`"test":"@doc(\"Captured by capture_tick: view_twin vs the live schedule for Counter over tick 0 of a recorded session.\")\n` +
		`test \"captured tick 0 Counter twin view_twin\" {\n` +
		`  assert view_twin(View.of([Counter{mark: 0}, Counter{mark: 0}])) == [Counter{mark: 7}, Counter{mark: 7}]\n}\n"}}`
	testing.expect_value(t, response, expected)
}

// Every unservable capture_tick is refused with a well-formed envelope, the
// refusal TYPED toward the agent: an absent twin, a twin whose signature is not
// `[T]/View[T] -> [T]`, an unknown thing, an out-of-range tick, and a missing
// required arg each name their cause.
@(test)
test_capture_tick_refusals :: proc(t: ^testing.T) {
	s := counter_tick_session()
	cases := [?]struct {
		request:  string,
		fragment: string,
	} {
		{
			`{"id":1,"cmd":"capture_tick","args":{"tick":0,"thing":"Counter","twin":"nope"}}`,
			`unknown twin function`,
		},
		{
			`{"id":2,"cmd":"capture_tick","args":{"tick":0,"thing":"Counter","twin":"wrong_twin"}}`,
			`twin wrong_twin must return [Counter]`,
		},
		{
			`{"id":3,"cmd":"capture_tick","args":{"tick":0,"thing":"Nope","twin":"mark_twin"}}`,
			`unknown thing`,
		},
		{
			`{"id":4,"cmd":"capture_tick","args":{"tick":99,"thing":"Counter","twin":"mark_twin"}}`,
			`tick out of range`,
		},
		{
			`{"id":5,"cmd":"capture_tick","args":{"thing":"Counter","twin":"mark_twin"}}`,
			`missing args.tick, args.thing, or args.twin`,
		},
	}
	for entry in cases {
		response := session_request(&s, entry.request)
		testing.expect(t, contains_substring(response, `"ok":false`), "a refused capture_tick must answer ok:false")
		testing.expect(t, contains_substring(response, entry.fragment), entry.fragment)
	}
}

// capture_tick is observe-class: a capture leaves the canonical chain digest-pinned
// bit-identical to an untouched reference — the §28 §2 warranty for the self-heal group.
@(test)
test_capture_tick_non_perturbing_digest_pin :: proc(t: ^testing.T) {
	s := counter_tick_session()
	baseline := session_capture(&s)

	response := session_request(&s, `{"id":1,"cmd":"capture_tick","args":{"tick":0,"thing":"Counter","twin":"mark_twin"}}`)
	testing.expect(t, contains_substring(response, `"ok":true`), "the capture must succeed")

	captured := session_capture(&s)
	if !testing.expect_value(t, len(captured.per_tick), len(baseline.per_tick)) {
		return
	}
	for frame, i in captured.per_tick {
		testing.expect_value(t, frame.digest, baseline.per_tick[i].digest)
	}
	testing.expect_value(t, captured.session, baseline.session)
}

// contains_substring is the test's tiny substring check (avoids importing strings
// for one call — the refusal/ok fragments are short literals).
@(private = "file")
contains_substring :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	for i in 0 ..= len(haystack) - len(needle) {
		if haystack[i:i + len(needle)] == needle {
			return true
		}
	}
	return false
}
