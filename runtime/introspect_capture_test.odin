// §28 §5 capture → test acceptance: `capture_test` exports an observed
// (state, inputs, expected) triple as a runnable funpack test block, and the
// EXACT exported bytes are pinned as goldens — the validation path the export
// contract allows when the consumer (the funpack compiler) lives across the
// product boundary. Every pinned text below was ALSO fed through the real
// compiler against its example project (`funpack check` parses it clean;
// `funpack test` evaluates the assert and passes), so the pins are
// known-parseable, known-passing funpack source, not merely frozen bytes.
//
// The acceptance golden is the SEEDED SNAKE capture the story demands: the
// eat tick's detect_eat — the (Snake state, View.of food fixture, [Eaten]
// expectation) triple whose food cell only the recorded seed can place. A
// second snake pin (turn at the scripted press tick) exercises the
// Input.empty().with_pressed producer-chain rebuild from the recorded
// snapshot; the pong pin exercises the exact-dyadic-decimal Fixed render and
// View.of over multi-row state.
package funpack_runtime

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

// capture_snake_session opens the seeded golden-snake session (seed 42, the
// scripted 16-tick run with one Down press at tick 6) — the same canonical
// run every seeded introspection battery folds.
@(private = "file")
capture_snake_session :: proc(
	t: ^testing.T,
	allocator := context.allocator,
) -> (
	session: Debug_Session,
) {
	program := new(Program, allocator)
	loaded, err := load_program(GOLDEN_SNAKE_ARTIFACT, allocator)
	testing.expect(t, err == .None, "golden snake artifact must load")
	program^ = loaded
	inputs := make([]Input, 16, allocator)
	for i in 0 ..< 16 {
		inputs[i] = i == 6 ? with_pressed(empty(), .P1, ActionId(1)) : empty()
	}
	return open_debug_session(program, inputs, seeded_run(42), allocator)
}

// THE ACCEPTANCE GOLDEN — the seeded snake eat-tick capture, pinned
// byte-for-byte: detect_eat's (self, View.of foods, [Eaten]) triple at tick 9,
// where the head shares the seed-placed food's cell. The exported text parses
// clean and passes under `funpack test` against the snake example project.
@(test)
test_capture_test_seeded_snake_golden :: proc(t: ^testing.T) {
	s := capture_snake_session(t)

	// Cross-check the pinned tick: tick 9 is the first boundary whose entering
	// Rng advances — the replenish draw the eat fires.
	eat_tick := -1
	for i in 0 ..< len(s.rngs) - 1 {
		if s.rngs[i + 1].state != s.rngs[i].state {
			eat_tick = i
			break
		}
	}
	testing.expect_value(t, eat_tick, 9)

	response := session_request(&s, `{"id":1,"cmd":"capture_test","args":{"tick":9,"behavior":"detect_eat"}}`)
	expected :=
		`{"v":1,"id":1,"ok":true,"cmd":"capture_test","result":{"tick":9,"behavior":"detect_eat","instance":0,` +
		`"test":"@doc(\"Captured by capture_test: detect_eat on Snake#0 at tick 9 of a recorded session.\")\n` +
		`test \"captured detect_eat tick 9 instance 0\" {\n` +
		`  assert detect_eat.step(` +
		`Snake{head: Cell{x: 16, y: 14}, body: [], dir: Dir::Down, grow: false, state: GameState::Playing}, ` +
		`View.of([Food{cell: Cell{x: 16, y: 14}}])) == [Eaten{cell: Cell{x: 16, y: 14}}]\n}\n"}}`
	testing.expect_value(t, response, expected)
}

// The Input fixture rebuild: turn at the scripted press tick exports the
// recorded snapshot as the Input.empty().with_pressed producer chain, and the
// expected Snake carries the turned heading — pinned byte-for-byte
// (parse-validated against the snake example like the golden above).
@(test)
test_capture_test_input_producer_chain :: proc(t: ^testing.T) {
	s := capture_snake_session(t)
	response := session_request(&s, `{"id":2,"cmd":"capture_test","args":{"tick":6,"behavior":"turn"}}`)
	expected :=
		`{"v":1,"id":2,"ok":true,"cmd":"capture_test","result":{"tick":6,"behavior":"turn","instance":0,` +
		`"test":"@doc(\"Captured by capture_test: turn on Snake#0 at tick 6 of a recorded session.\")\n` +
		`test \"captured turn tick 6 instance 0\" {\n` +
		`  assert turn.step(` +
		`Snake{head: Cell{x: 16, y: 10}, body: [], dir: Dir::Right, grow: false, state: GameState::Playing}, ` +
		`Input.empty().with_pressed(PlayerId::P1, Move::Down)) == ` +
		`Snake{head: Cell{x: 16, y: 10}, body: [], dir: Dir::Down, grow: false, state: GameState::Playing}\n}\n"}}`
	testing.expect_value(t, response, expected)
}

// The Fixed render is the EXACT dyadic decimal (Q32.32 fractions terminate in
// base 10), and a View.of fixture carries every row of the viewed thing in
// stable Id order — pinned over the seedless golden pong run, whose tick-3
// ball/paddle state has non-trivial fractional bits. Parse-validated against
// the pong example project.
@(test)
test_capture_test_fixed_decimal_and_view_fixture :: proc(t: ^testing.T) {
	program := new(Program, context.allocator)
	loaded, err := load_program(GOLDEN_ARTIFACT, context.allocator)
	testing.expect(t, err == .None, "golden pong artifact must load")
	program^ = loaded
	session := open_debug_session(program, golden_session_inputs(context.allocator), NO_SEED, context.allocator)
	s := session

	response := session_request(&s, `{"id":3,"cmd":"capture_test","args":{"tick":3,"behavior":"paddle_bounce"}}`)
	expected :=
		`{"v":1,"id":3,"ok":true,"cmd":"capture_test","result":{"tick":3,"behavior":"paddle_bounce","instance":0,` +
		`"test":"@doc(\"Captured by capture_test: paddle_bounce on Ball#0 at tick 3 of a recorded session.\")\n` +
		`test \"captured paddle_bounce tick 3 instance 0\" {\n` +
		`  assert paddle_bounce.step(` +
		`Ball{pos: Vec2{x: 84.666666649281978607177734375, y: 62.6666666567325592041015625}, vel: Vec2{x: 70.0, y: 40.0}}, ` +
		`View.of([Paddle{player: PlayerId::P1, side: Side::Left, x: 8.0, y: 60.0, speed: 90.0}, ` +
		`Paddle{player: PlayerId::P2, side: Side::Right, x: 152.0, y: 65.999999977648258209228515625, speed: 90.0}])) == ` +
		`Ball{pos: Vec2{x: 84.666666649281978607177734375, y: 62.6666666567325592041015625}, vel: Vec2{x: 70.0, y: 40.0}}\n}\n"}}`
	testing.expect_value(t, response, expected)
}

// capture_test is observe-class: a capture battery (the golden export plus an
// Input-chain export) leaves the canonical seeded chain digest-pinned
// bit-identical to an untouched reference — the §28 §2 warranty extended to
// the self-heal group.
@(test)
test_capture_test_non_perturbing_digest_pin :: proc(t: ^testing.T) {
	s := capture_snake_session(t)
	baseline := session_capture(&s)

	battery := [?]string {
		`{"id":1,"cmd":"capture_test","args":{"tick":9,"behavior":"detect_eat"}}`,
		`{"id":2,"cmd":"capture_test","args":{"tick":6,"behavior":"turn"}}`,
	}
	for request in battery {
		response := session_request(&s, request)
		testing.expect(t, strings.contains(response, `"ok":true`), "every capture in the battery must succeed")
	}

	captured := session_capture(&s)
	if !testing.expect_value(t, len(captured.per_tick), len(baseline.per_tick)) {
		return
	}
	for frame, i in captured.per_tick {
		testing.expect_value(t, frame.digest, baseline.per_tick[i].digest)
	}
	testing.expect_value(t, captured.session, baseline.session)
}

// Every unservable capture is refused with a well-formed envelope — and the
// refusals are TYPED toward the agent: a read with no deterministic source
// constructor (replenish's threaded rng) names the param, so the agent
// captures at a constructible boundary instead of receiving a broken test.
@(test)
test_capture_test_refusals :: proc(t: ^testing.T) {
	s := capture_snake_session(t)

	cases := [?]struct {
		request:  string,
		fragment: string,
	} {
		{
			`{"id":1,"cmd":"capture_test","args":{"tick":9,"behavior":"replenish"}}`,
			`param rng: Rng has no deterministic source constructor`,
		},
		{`{"id":2,"cmd":"capture_test","args":{"tick":0,"behavior":"nope"}}`, `unknown behavior`},
		{`{"id":3,"cmd":"capture_test","args":{"tick":99,"behavior":"turn"}}`, `tick out of range`},
		{`{"id":4,"cmd":"capture_test","args":{"behavior":"turn"}}`, `missing args.tick`},
		{
			`{"id":5,"cmd":"capture_test","args":{"tick":0,"behavior":"turn","instance":7}}`,
			`no captured step for that behavior and instance`,
		},
	}
	for entry in cases {
		response := session_request(&s, entry.request)
		testing.expect(t, strings.contains(response, `"ok":false`), "a refused capture must answer ok:false")
		testing.expect(t, strings.contains(response, entry.fragment), entry.fragment)
	}
}

// ── the committed-copy seam for the cross-product guard ──────────────────

// expect_capture_matches_file pins one live capture export against its
// committed copy under testdata/: the response's result.test payload must be
// byte-equal to the file. The committed copies are the funpack compiler's
// cross-product guard input (its guard test parses and runs those bytes), so
// this pin keeps the live exporter and the committed seam from drifting apart
// silently — the krognid committed-copy discipline applied to the §28 §5
// export contract.
@(private = "file")
expect_capture_matches_file :: proc(t: ^testing.T, s: ^Debug_Session, request: string, path: string) {
	response := session_request(s, request)
	parsed, parse_err := json.parse_string(response, allocator = context.temp_allocator)
	testing.expectf(t, parse_err == nil, "capture response must parse as JSON: %s", path)
	if parse_err != nil {
		return
	}
	root, is_object := parsed.(json.Object)
	testing.expect(t, is_object)
	if !is_object {
		return
	}
	result, has_result := root["result"].(json.Object)
	testing.expectf(t, has_result, "capture response must carry a result: %s", path)
	if !has_result {
		return
	}
	exported, is_string := result["test"].(json.String)
	testing.expect(t, is_string)
	file_bytes, file_err := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expectf(t, file_err == nil, "committed capture copy must read: %s", path)
	if file_err != nil {
		return
	}
	testing.expect_value(t, exported, string(file_bytes))
}

@(test)
test_capture_export_committed_copies_lockstep :: proc(t: ^testing.T) {
	s := capture_snake_session(t)
	expect_capture_matches_file(
		t,
		&s,
		`{"id":1,"cmd":"capture_test","args":{"tick":9,"behavior":"detect_eat"}}`,
		"testdata/capture_snake_eat.fun",
	)
	expect_capture_matches_file(
		t,
		&s,
		`{"id":2,"cmd":"capture_test","args":{"tick":6,"behavior":"turn"}}`,
		"testdata/capture_snake_turn.fun",
	)

	program := new(Program, context.allocator)
	loaded, err := load_program(GOLDEN_ARTIFACT, context.allocator)
	testing.expect(t, err == .None, "golden pong artifact must load")
	program^ = loaded
	pong := open_debug_session(program, golden_session_inputs(context.allocator), NO_SEED, context.allocator)
	expect_capture_matches_file(
		t,
		&pong,
		`{"id":3,"cmd":"capture_test","args":{"tick":3,"behavior":"paddle_bounce"}}`,
		"testdata/capture_pong_paddle_bounce.fun",
	)
}
