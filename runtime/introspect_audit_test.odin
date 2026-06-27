package funpack_runtime

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
audit_pong_session :: proc(
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
test_audit_warranted_recording_is_bit_identical :: proc(t: ^testing.T) {
	_, inputs, session := audit_pong_session(t)
	s := session

	response := session_request(&s, `{"id":1,"cmd":"audit"}`)

	testing.expect(t, strings.contains(response, `"ok":true`), "audit must succeed on a warranted recording")
	testing.expect(t, strings.contains(response, `"warranted":true`), "a warranted recording must report warranted:true")
	testing.expect(
		t,
		!strings.contains(response, `"diverged"`),
		"a warranted recording must emit no diverged event",
	)
	testing.expect(
		t,
		strings.contains(response, audit_ticks_fragment(len(inputs))),
		"audit must report ticks_audited == the recorded tick count",
	)
	recorded := session_capture(&s)
	testing.expect(
		t,
		strings.contains(response, session_pair_fragment(recorded.session, recorded.session)),
		"recorded and reproduced session digests must match on a warranted recording",
	)
}

@(test)
test_audit_tampered_recording_reports_first_divergence :: proc(t: ^testing.T) {
	_, _, session := audit_pong_session(t)
	s := session

	recorded := session_capture(&s)

	tampered_tick := 10
	s.snapshots[tampered_tick] = empty()

	response := session_request(&s, `{"id":2,"cmd":"audit"}`)

	testing.expect(t, strings.contains(response, `"ok":true`), "audit is observe-class — it answers ok:true even when it finds a divergence")
	testing.expect(t, strings.contains(response, `"warranted":false`), "a tampered recording must report warranted:false")
	testing.expect(
		t,
		strings.contains(response, `"diverged":{`),
		"a tampered recording must emit the diverged event object",
	)
	testing.expect(
		t,
		strings.contains(response, `"event":"diverged"`),
		"the diverged object must be the §28 §3 diverged async-event shape",
	)

	divergence, diverged := first_frame_divergence(recorded, audit_refold_capture_for_test(&s))
	testing.expect(t, diverged, "the tampered re-fold must diverge from the recorded baseline")
	testing.expect(
		t,
		divergence.recorded != divergence.reproduced,
		"the divergence must carry differing recorded and reproduced digests",
	)
	testing.expect(
		t,
		strings.contains(response, divergence_tick_fragment(divergence.tick)),
		"the diverged event must name the first diverging tick",
	)
	testing.expect(
		t,
		divergence.tick >= tampered_tick,
		"the first divergence cannot precede the tampered tick (earlier ticks folded from identical input)",
	)
}

@(test)
test_audit_does_not_perturb_the_canonical_digest :: proc(t: ^testing.T) {
	_, _, session := audit_pong_session(t)
	s := session

	before := session_capture(&s)

	_ = session_request(&s, `{"id":1,"cmd":"audit"}`)
	s.snapshots[10] = empty()
	_ = session_request(&s, `{"id":2,"cmd":"audit"}`)

	after := session_capture(&s)

	testing.expect_value(t, len(after.per_tick), len(before.per_tick))
	for frame, i in after.per_tick {
		testing.expect_value(t, frame.tick, before.per_tick[i].tick)
		testing.expect_value(t, frame.digest, before.per_tick[i].digest)
	}
	testing.expect_value(t, after.session, before.session)
}

@(private = "file")
audit_refold_capture_for_test :: proc(s: ^Debug_Session, allocator := context.allocator) -> Frame_Capture {
	world := new_world(s.program^, allocator)
	base := initial_version(world, allocator)
	tick_hz := s.program.entrypoint.tick_hz
	per_tick := make([dynamic]Frame_Digest, 0, len(s.snapshots), allocator)
	version := run_startup(s.program, base, allocator)
	for snapshot, i in s.snapshots {
		time := time_resource_at(tick_hz, i, allocator)
		version = step_tick(s.program, version, snapshot, time, allocator)
		draw := render_version(s.program, version, snapshot, time, allocator)
		append(&per_tick, capture_frame(version, draw, allocator))
	}
	return finish_capture(per_tick[:], allocator)
}

@(private = "file")
audit_ticks_fragment :: proc(n: int, allocator := context.allocator) -> string {
	return fmt.aprintf(`"ticks_audited":%d`, n, allocator = allocator)
}

@(private = "file")
divergence_tick_fragment :: proc(tick: int, allocator := context.allocator) -> string {
	return fmt.aprintf(`"tick":%d`, tick, allocator = allocator)
}

@(private = "file")
session_pair_fragment :: proc(recorded, reproduced: u64, allocator := context.allocator) -> string {
	return fmt.aprintf(
		`"recorded_session":%d,"reproduced_session":%d`,
		recorded,
		reproduced,
		allocator = allocator,
	)
}
