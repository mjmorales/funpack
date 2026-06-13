// §28 §3 self-heal `audit` acceptance — the determinism-warranty audit, the
// observe-class twin of capture_test (introspect_audit.odin). Three behaviors are
// pinned over the golden pong recording (seedless — Input is the sole recorded
// nondeterminism source, Lore #9):
//   1. WARRANTED — auditing an untampered recording reports warranted:true, audits
//      every recorded tick, and emits no diverged object (the re-run reproduces the
//      recorded frame digests bit-identically).
//   2. DIVERGENT — auditing a TAMPERED recording (one recorded snapshot mutated
//      post-open, so the recording no longer reproduces its own digests) reports
//      warranted:false with the diverged event naming the FIRST diverging tick and
//      the recorded-vs-reproduced digest diff.
//   3. NON-PERTURBATION — auditing changes NO canonical digest: the session's
//      per-tick + session frame digests are byte-identical before and after the
//      audit (audit is observe-class, it preserves the warranty it checks).
package funpack_runtime

import "core:fmt"
import "core:strings"
import "core:testing"

// audit_pong_session loads the golden pong artifact and opens an observe session
// over the EXACT golden pong run (golden_session_inputs — the shared script the
// replay/probe goldens fold from). Seedless: pong has no RNG. Returns the inputs so
// a tamper test can mutate the session's recorded snapshot slice.
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

// A warranted recording audits clean: the fresh re-fold from the recording's own
// snapshot reproduces every recorded frame digest, so the verdict is warranted:true
// with no diverged object. This is the property the whole capture/replay/rewind loop
// rests on — proven, not assumed.
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
	// The whole recorded run is audited (one digest per committed tick).
	testing.expect(
		t,
		strings.contains(response, audit_ticks_fragment(len(inputs))),
		"audit must report ticks_audited == the recorded tick count",
	)
	// The recorded and reproduced session digests are the one-value whole-run
	// summary; under a warranted recording they are equal.
	recorded := session_capture(&s)
	testing.expect(
		t,
		strings.contains(response, session_pair_fragment(recorded.session, recorded.session)),
		"recorded and reproduced session digests must match on a warranted recording",
	)
}

// A TAMPERED recording fails the warranty: mutating one recorded snapshot AFTER the
// session folded its canonical chain means the recording's stored digests no longer
// match what its (now-altered) inputs reproduce — exactly the broken determinism
// warranty audit exists to catch. The verdict is warranted:false with the diverged
// event naming the first diverging tick and the digest diff.
@(test)
test_audit_tampered_recording_reports_first_divergence :: proc(t: ^testing.T) {
	_, _, session := audit_pong_session(t)
	s := session

	// The recorded baseline the session folded at open (from the ORIGINAL inputs).
	recorded := session_capture(&s)

	// TAMPER: drop the steer input at an early steered tick. The session's retained
	// chain (s.versions) was folded from the original steered input, but the re-fold
	// reads s.snapshots — now altered — so the re-run diverges at the first tick the
	// paddle position differs. (Tick 10 is within the first GOLDEN_STEER_TICKS=26
	// steered ticks.) This mutates a recorded determinism INPUT (Lore #9), not an
	// internal version structure — a faithful tampered recording.
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

	// The diverged event localizes the FIRST diverging tick with both digests; the
	// recorded and reproduced digests at that tick must differ (a real divergence,
	// not a spurious equal pair).
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
	// The first divergence cannot PRECEDE the tampered tick — every tick before it
	// folded from identical input, so its committed digest is unchanged. (The exact
	// diverging tick is a sim commit-timing detail — the altered input perturbs the
	// committed state at the tampered tick or the one immediately after — so the
	// invariant pinned here is the lower bound, not the precise ordinal.)
	testing.expect(
		t,
		divergence.tick >= tampered_tick,
		"the first divergence cannot precede the tampered tick (earlier ticks folded from identical input)",
	)
}

// Auditing is observe-class: it re-folds into scratch and reads the canonical chain,
// never writing it. So the session's canonical frame digests — per-tick AND the
// session fold — are byte-identical before and after an audit. This is the warranty
// audit itself rests on: the diagnostic for the determinism warranty must not perturb
// the determinism warranty.
@(test)
test_audit_does_not_perturb_the_canonical_digest :: proc(t: ^testing.T) {
	_, _, session := audit_pong_session(t)
	s := session

	before := session_capture(&s)

	// Audit twice — a warranted and (after tamper) a divergent audit — to prove
	// neither path writes the canonical chain.
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

// audit_refold_capture_for_test exposes the file-private re-fold capture to the
// divergence assertion above — the SAME independent re-run audit_request drives, so
// the test compares against exactly what the command computed.
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

// --- response-fragment builders (byte-stable substrings the verdict must carry) ---

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
