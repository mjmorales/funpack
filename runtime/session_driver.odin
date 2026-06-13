// §28 §5 AGENT-DRIVEN LIVE-VERIFICATION DRIVER — the autonomous loop that closes
// the human-in-the-loop gap: an agent boots a game artifact headless, drives the
// §28 observe/control/time session + the honored debug probes, ASSERTS a stated
// live-behavior predicate over the observed committed state, and ON PASS exports the
// observation as a `capture_test` regression that joins the suite. It is the
// substrate the dungeon-crawler "Run the game: does X happen?" gate criteria consume
// — but proven here against an EXISTING runtime test artifact, never the dungeon
// (which lives in a sibling repo and is not built here).
//
// THE LOOP (§28 §5 "the debugger's output IS a regression test"):
//   load → run{until:N} → assert(live predicate over observed state / honored probes)
//   → ON PASS: capture_test → return the emitted funpack test (the regression).
// The agent fixes the behavior, hot-reloads, re-runs the captured test, and the
// captured `test` lands in source as a permanent, never-flaky regression — exactly
// the §28 §5 cycle, but driven by THIS code instead of a human watching the SDL
// window.
//
// IT IS A HEADLESS IN-PROCESS DRIVER, NOT A CLI VERB (the engine-boundary decision,
// recorded in the run reasoning log runtime-3.2-driver-shape-decision). The §28
// session fold (session_request, introspect.odin) is transport-agnostic by its own
// header and harness-testable without a socket; this driver is the SAME client an
// agent or CI would be, scripted in-process over the pure fold. The runtime CLI is
// ENTIRELY behind when #config(FUNPACK_LIVE) (main.odin / session_live.odin), so a
// CLI verb would compile the verifier into the SDL-gated block the deterministic
// suite never builds — the opposite of a self-verification path. A thin FUNPACK_LIVE
// CLI arm can call drive_verification later (the run_attach_server when-gated
// thin-adapter shape); this file edits no existing file.
//
// THE LIVE-BEHAVIOR PREDICATE IS THE SPEC VALUE LANGUAGE, NEVER A NEW DSL (§28 §2:
// "There is no debugger DSL"). Two spec-honoring forms the substrate already owns,
// AND-combined:
//   (A) a COMMITTED-STATE assertion — read a (thing, instance, field) at the run's
//       target tick through the EXISTING observe surface and compare it to a stated
//       EXPECTED value supplied PRE-ENCODED in the artifact's own value encoding (§28
//       §2: "client-injected values ship pre-encoded in the artifact's value
//       encoding"). The compare is STRUCTURAL (decode_default_value → field_values_
//       equal), not a fragile string match.
//   (B) a PROBE-FIRING assertion — assert a named @watch/@break fired (watch_fired /
//       breakpoint_hit) during the run, the §28 §5 "a watchpoint predicate IS a test
//       assertion" clause realized directly on the honored-probe stream
//       (session_honor_probes, probes.odin).
//
// DETERMINISM WARRANTY PRESERVED (§28 §2). Every driver step is OBSERVE-CLASS: the
// session script issues only observe/time commands (load/run) + the observe-class
// capture_test; the predicate reads the retained COW chain and the probe honor re-
// folds into request scratch; capture_test emits a pure test. The driver NEVER
// perturbs the canonical fold — a driven run digests bit-identical to an undriven
// one (the non-perturbation pin in session_driver_acceptance_test.odin holds the
// warranty, exactly as introspect_test.odin / probes_test.odin do for the session
// and the probe honor).
package funpack_runtime

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// State_Assertion is the §28 §2 committed-state half of a live-behavior predicate:
// at the run's target tick the named thing's instance must carry `field` equal to
// `expected_encoded` — the expected value in the artifact's own literal encoding (the
// same form decode_default_value reads, so the agent supplies it the way the artifact
// carries a default). `type_name` is the field's declared type, the decode hint the
// codec needs (Int/Fixed/Bool/Vec2/a record/enum/list type). The compare is
// STRUCTURAL (the decoded Field_Value vs the observed one via field_values_equal), so
// two equal values that render to different incidental byte forms still match — the
// predicate is over VALUES, never over rendered strings.
State_Assertion :: struct {
	thing:            string, // the thing type whose row carries the asserted field
	instance:         Thing_Id, // the row's stable Id (0 = the first/singleton instance)
	field:            string, // the blackboard field the predicate reads
	type_name:        string, // the field's declared type — the decode hint for expected_encoded
	expected_encoded: string, // the expected value, artifact literal encoding (§28 §2 pre-encoded)
}

// Probe_Assertion is the §28 §5 probe-firing half: a named @watch/@break must have
// fired AT LEAST `min_fires` times during the run (the default, 1, is "it fired") —
// "a watchpoint predicate IS a test assertion." `target` is the probe's §28 §2
// index-identity target (the behavior name the @break/@watch is attached to, or the
// watched thing for a @watch-on-field). `kind` selects which honored stream to count
// (.Break → breakpoint_hit, .Watch → watch_fired); .Log/.Trace are not predicate
// surfaces (they always fire) and are rejected by the driver.
Probe_Assertion :: struct {
	target:    string,
	kind:      Probe_Kind,
	min_fires: int,
}

// Live_Predicate is the whole live-behavior assertion the driver evaluates at the
// run's target tick — the AND of an optional committed-state assertion and an
// optional probe-firing assertion (§28 §2 value language, both forms). `until` is the
// tick the session runs to before asserting (the §28 §3 synchronous `run` target). At
// least one of the two assertion arms must be present; a predicate with neither is a
// vacuous pass the driver refuses (a gate that asserts nothing verifies nothing).
Live_Predicate :: struct {
	until:        int,
	has_state:    bool,
	state:        State_Assertion,
	has_probe:    bool,
	probe:        Probe_Assertion,
}

// Capture_Spec names the regression the driver exports ON PASS — the §28 §5
// capture_test arguments: the behavior to capture, and optionally the tick and the
// instance. `has_tick` distinguishes "capture at tick T" from "default to the
// predicate's verified `until` tick" (so the common case — capture at the boundary we
// just verified — needs no separate field, and tick 0 is still expressible by setting
// has_tick). `has_instance` selects the behavior instance, defaulting to the first in
// fold order like the bare capture_test. The export is the funpack `test` block the
// loop lands in source.
Capture_Spec :: struct {
	behavior:     string,
	has_tick:     bool,
	tick:         int,
	has_instance: bool,
	instance:     Thing_Id,
}

// Verification is the driver's outcome: whether the live predicate held, a one-line
// human reason (the assertion that failed, or "pass"), and — ON PASS — the exported
// capture_test regression (the funpack `test` source the loop lands). `captured` is
// false when the predicate failed (no regression is exported from a failing gate) or
// when the on-pass capture_test itself refused (an unconstructible boundary — the
// reason names it). The driver returns a Verification, never a process side effect, so
// a caller (a test, a CI step, the future CLI arm) decides what to do with it.
Verification :: struct {
	passed:    bool,
	reason:    string, // one-line human verdict — the failing assertion, or "pass"
	captured:  bool, // a regression was exported (passed AND capture_test succeeded)
	test_src:  string, // the exported funpack `test` block (empty unless captured)
}

// drive_verification runs the whole §28 §5 loop over an already-opened session: it
// scripts the NDJSON session to the predicate's target tick (load → run), evaluates
// the live-behavior predicate over the observed committed state and the honored-probe
// stream, and ON PASS scripts a capture_test to export the regression. It is the
// agent-facing entry — the same sequence an agent would drive over the wire, run
// in-process over the pure fold.
//
// The session is BORROWED (the caller opened it via open_debug_session over a booted
// artifact + recorded snapshots); the driver issues only observe-class commands, so it
// leaves the session's canonical chain untouched (the determinism warranty). All
// scratch is on `allocator`; the returned strings (reason, test_src) are allocated
// there.
drive_verification :: proc(
	s: ^Debug_Session,
	predicate: Live_Predicate,
	capture: Capture_Spec,
	allocator := context.allocator,
) -> Verification {
	if !predicate.has_state && !predicate.has_probe {
		return Verification{passed = false, reason = "vacuous predicate: a verification gate must assert at least one of state or probe"}
	}

	// (1) RUN TO THE TARGET TICK over the §28 NDJSON session — the same load → run
	// an agent issues. `run` is synchronous to its target (§28 §3): its response is
	// the run's completion, so once it returns ok the cursor sits at `until`.
	if ran_ok, run_err := session_run_to(s, predicate.until, allocator); !ran_ok {
		return Verification{passed = false, reason = run_err}
	}

	// (2) EVALUATE THE LIVE-BEHAVIOR PREDICATE — the AND of the committed-state and
	// probe-firing arms, each in the §28 §2 value language. The first failing arm is
	// the verdict; a gate passes only when EVERY asserted arm holds.
	if predicate.has_state {
		if held, why := evaluate_state_assertion(s, predicate.until, predicate.state, allocator); !held {
			return Verification{passed = false, reason = why}
		}
	}
	if predicate.has_probe {
		if held, why := evaluate_probe_assertion(s, predicate.probe, allocator); !held {
			return Verification{passed = false, reason = why}
		}
	}

	// (3) ON PASS — EXPORT THE CAPTURE_TEST REGRESSION (§28 §5: the debugger's output
	// IS a regression test). Script the capture_test command exactly as the agent
	// would; the emitted funpack `test` is the regression the loop lands in source.
	test_src, capture_ok, capture_err := export_capture_test(s, predicate, capture, allocator)
	if !capture_ok {
		// The predicate HELD, but the observation is not capturable as a runnable test
		// (an unconstructible boundary — capture_test names it). The gate still PASSES
		// (the live behavior was verified); the loop just cannot emit a regression from
		// this exact boundary, so the reason carries capture_test's typed refusal.
		return Verification {
			passed = true,
			reason = fmt.aprintf("pass; regression not captured: %s", capture_err, allocator = allocator),
		}
	}
	return Verification{passed = true, reason = "pass", captured = true, test_src = test_src}
}

// session_run_to scripts the §28 §3 time group to advance the session to `target`: a
// `load` to arm the cursor, then a `run{until:target}` (synchronous to its target).
// It drives the SAME session_request fold an agent would — the response envelopes are
// parsed for the `ok` boolean, so a refusal (a target out of range) surfaces as the
// run's error text, never a silent miss. ok=false carries a one-line reason.
session_run_to :: proc(
	s: ^Debug_Session,
	target: int,
	allocator := context.allocator,
) -> (
	ok: bool,
	reason: string,
) {
	load_resp := session_request(s, `{"cmd":"load"}`, allocator)
	if !response_ok(load_resp, allocator) {
		return false, "session load failed"
	}
	run_line := fmt.aprintf(`{{"cmd":"run","args":{{"until":%d}}}}`, target, allocator = allocator)
	run_resp := session_request(s, run_line, allocator)
	if !response_ok(run_resp, allocator) {
		return false, fmt.aprintf("run to tick %d refused: %s", target, response_error(run_resp, allocator), allocator = allocator)
	}
	return true, ""
}

// evaluate_state_assertion reads the asserted (thing, instance, field) at the target
// tick off the session's retained canonical chain — the SAME committed-state read the
// observe commands do (session_version_at / version_find_table) — and compares it
// STRUCTURALLY to the decoded expected value. The expected literal is decoded through
// decode_default_value (the §28 §2 pre-encoded value form, the artifact codec's
// inverse) so a Fixed/Vec2/record expected value compares by VALUE, not by incidental
// rendering. held=false carries a one-line reason naming exactly what diverged (an
// absent table/row/field, a decode failure, or the observed-vs-expected mismatch
// rendered for the operator).
evaluate_state_assertion :: proc(
	s: ^Debug_Session,
	tick: int,
	assertion: State_Assertion,
	allocator := context.allocator,
) -> (
	held: bool,
	reason: string,
) {
	version, version_ok := session_version_at(s, tick)
	if !version_ok {
		return false, fmt.aprintf("state assertion: tick %d out of range", tick, allocator = allocator)
	}
	table := version_find_table(&version, assertion.thing)
	if table == nil {
		return false, fmt.aprintf("state assertion: no thing %q in the world", assertion.thing, allocator = allocator)
	}
	row_idx, found := find_row_by_id(table.rows, Id{raw = assertion.instance})
	if !found {
		return false, fmt.aprintf("state assertion: no %s instance #%d at tick %d", assertion.thing, assertion.instance, tick, allocator = allocator)
	}
	observed, has_field := table.rows[row_idx].fields[assertion.field]
	if !has_field {
		return false, fmt.aprintf("state assertion: %s#%d has no field %q", assertion.thing, assertion.instance, assertion.field, allocator = allocator)
	}
	expected, decode_ok := decode_default_value(s.program, assertion.type_name, assertion.expected_encoded, allocator)
	if !decode_ok {
		return false, fmt.aprintf("state assertion: cannot decode expected %q as %s", assertion.expected_encoded, assertion.type_name, allocator = allocator)
	}
	if !field_values_equal(observed, expected) {
		return false, fmt.aprintf(
			"state assertion failed: %s#%d.%s is %s, expected %s",
			assertion.thing,
			assertion.instance,
			assertion.field,
			field_value_text(observed, allocator),
			field_value_text(expected, allocator),
			allocator = allocator,
		)
	}
	return true, ""
}

// evaluate_probe_assertion re-folds the recorded run with the probe-honor tap armed
// (session_honor_probes — the SAME bounded re-fold the live break/watch group drives,
// observe-class by construction) and counts the firings of the asserted probe on its
// stream: a .Break assertion counts breakpoint_hit firings on `target`, a .Watch
// assertion counts watch_fired firings on `target`. held=true when the count meets
// `min_fires`. .Log/.Trace are not predicate surfaces (they fire unconditionally
// every step), so asserting on one is a usage error the driver rejects.
evaluate_probe_assertion :: proc(
	s: ^Debug_Session,
	assertion: Probe_Assertion,
	allocator := context.allocator,
) -> (
	held: bool,
	reason: string,
) {
	if assertion.kind != .Break && assertion.kind != .Watch {
		return false, "probe assertion: only @break (breakpoint_hit) and @watch (watch_fired) are predicate surfaces"
	}
	min_fires := assertion.min_fires
	if min_fires < 1 {
		min_fires = 1
	}
	honor, _ := session_honor_probes(s, allocator)
	fires := 0
	switch assertion.kind {
	case .Break:
		for hit in honor.breaks {
			if hit.target == assertion.target {
				fires += 1
			}
		}
	case .Watch:
		for fire in honor.watches {
			if fire.target == assertion.target {
				fires += 1
			}
		}
	case .Log, .Trace:
	// unreachable — guarded above; the closed enum forces the arms.
	}
	if fires < min_fires {
		kind_event := assertion.kind == .Break ? "breakpoint_hit" : "watch_fired"
		return false, fmt.aprintf(
			"probe assertion failed: %s on %q fired %d time(s), expected >= %d",
			kind_event,
			assertion.target,
			fires,
			min_fires,
			allocator = allocator,
		)
	}
	return true, ""
}

// export_capture_test scripts the §28 §5 capture_test command for the on-pass
// regression and extracts the emitted funpack `test` from the response. The capture
// tick defaults to the predicate's `until` (capture at the verified boundary); the
// behavior is the Capture_Spec's. It drives the SAME session_request fold — so the
// exported bytes are EXACTLY what the agent would receive over the wire — and lifts
// the `result.test` field out of the JSON envelope. ok=false carries capture_test's
// own typed refusal (an unconstructible boundary names the param), which the loop
// surfaces verbatim so the agent captures at a constructible boundary instead.
export_capture_test :: proc(
	s: ^Debug_Session,
	predicate: Live_Predicate,
	capture: Capture_Spec,
	allocator := context.allocator,
) -> (
	test_src: string,
	ok: bool,
	err: string,
) {
	// Capture at the explicit tick when given, else the predicate's verified boundary
	// — has_tick disambiguates the two without overloading tick 0 as a sentinel.
	tick := capture.has_tick ? capture.tick : predicate.until
	line: string
	if capture.has_instance {
		line = fmt.aprintf(
			`{{"cmd":"capture_test","args":{{"tick":%d,"behavior":%s,"instance":%d}}}}`,
			tick,
			json_quote(capture.behavior, allocator),
			capture.instance,
			allocator = allocator,
		)
	} else {
		line = fmt.aprintf(
			`{{"cmd":"capture_test","args":{{"tick":%d,"behavior":%s}}}}`,
			tick,
			json_quote(capture.behavior, allocator),
			allocator = allocator,
		)
	}
	resp := session_request(s, line, allocator)
	return capture_test_from_response(resp, allocator)
}

// capture_test_from_response lifts the §28 §5 exported funpack `test` out of a
// capture_test response envelope: `{…,"ok":true,…,"result":{…,"test":"<source>"}}`.
// ok=false on a refusal envelope (the error text is the reason) or a shape the
// reader does not recognize — the driver never best-effort-parses a malformed
// response. The `test` value is the runnable funpack source the regression loop
// lands in the suite.
capture_test_from_response :: proc(
	resp: string,
	allocator := context.allocator,
) -> (
	test_src: string,
	ok: bool,
	err: string,
) {
	parsed, parse_err := json.parse_string(resp, allocator = allocator)
	if parse_err != nil {
		return "", false, "capture_test response did not parse as JSON"
	}
	root, is_object := parsed.(json.Object)
	if !is_object {
		return "", false, "capture_test response was not a JSON object"
	}
	if ok_value, has_ok := root["ok"].(json.Boolean); !has_ok || !bool(ok_value) {
		return "", false, response_error_object(root, allocator)
	}
	result, has_result := root["result"].(json.Object)
	if !has_result {
		return "", false, "capture_test response carried no result"
	}
	source, has_test := result["test"].(json.String)
	if !has_test {
		return "", false, "capture_test result carried no test source"
	}
	return strings.clone(string(source), allocator), true, ""
}

// --- Response-envelope helpers (the driver reads the SAME envelopes it scripts) ---

// response_ok reports whether a §28 response envelope carries `"ok":true`. A
// malformed envelope (one the parser rejects) reads as not-ok — the driver fails
// closed on a response it cannot understand, never proceeding on a best-effort parse.
@(private = "file")
response_ok :: proc(resp: string, allocator := context.allocator) -> bool {
	parsed, parse_err := json.parse_string(resp, allocator = allocator)
	if parse_err != nil {
		return false
	}
	object, is_object := parsed.(json.Object)
	if !is_object {
		return false
	}
	value, has_ok := object["ok"].(json.Boolean)
	return has_ok && bool(value)
}

// response_error extracts the `error` text from a refusal envelope, or a generic
// note when the envelope carries none — the one-line reason the driver surfaces for a
// refused command.
@(private = "file")
response_error :: proc(resp: string, allocator := context.allocator) -> string {
	parsed, parse_err := json.parse_string(resp, allocator = allocator)
	if parse_err != nil {
		return "unparseable response"
	}
	object, is_object := parsed.(json.Object)
	if !is_object {
		return "non-object response"
	}
	return response_error_object(object, allocator)
}

// response_error_object reads the `error` string off an already-parsed envelope.
@(private = "file")
response_error_object :: proc(object: json.Object, allocator := context.allocator) -> string {
	if text, has_error := object["error"].(json.String); has_error {
		return strings.clone(string(text), allocator)
	}
	return "command refused without an error message"
}

// json_quote renders a string as a JSON string literal for inlining into a scripted
// request line (the command surface's `behavior` arg). It reuses write_json_string,
// the one JSON-string escaper the envelope renderers use, so a behavior name with a
// quote or backslash is escaped identically to every other wire string.
@(private = "file")
json_quote :: proc(text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write_json_string(&b, text)
	return strings.to_string(b)
}

// field_value_text renders one committed Field_Value in the artifact literal encoding
// — the human form the state-assertion mismatch reason shows (observed vs expected).
// It reuses render_field_value_text, the same encoder the observe payloads use, so a
// reported value reads exactly as it would on the wire.
@(private = "file")
field_value_text :: proc(value: Field_Value, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	render_field_value_text(&b, value)
	return strings.to_string(b)
}
