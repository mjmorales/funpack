package funpack_runtime

import "core:encoding/json"
import "core:fmt"
import "core:strings"

State_Assertion :: struct {
	thing:            string,
	instance:         Thing_Id,
	field:            string,
	type_name:        string,
	expected_encoded: string,
}

Probe_Assertion :: struct {
	target:    string,
	kind:      Probe_Kind,
	min_fires: int,
}

Live_Predicate :: struct {
	until:        int,
	has_state:    bool,
	state:        State_Assertion,
	has_probe:    bool,
	probe:        Probe_Assertion,
}

Capture_Spec :: struct {
	behavior:     string,
	has_tick:     bool,
	tick:         int,
	has_instance: bool,
	instance:     Thing_Id,
}

Verification :: struct {
	passed:    bool,
	reason:    string,
	captured:  bool,
	test_src:  string,
}

drive_verification :: proc(
	s: ^Debug_Session,
	predicate: Live_Predicate,
	capture: Capture_Spec,
	allocator := context.allocator,
) -> Verification {
	if !predicate.has_state && !predicate.has_probe {
		return Verification{passed = false, reason = "vacuous predicate: a verification gate must assert at least one of state or probe"}
	}

	if ran_ok, run_err := session_run_to(s, predicate.until, allocator); !ran_ok {
		return Verification{passed = false, reason = run_err}
	}

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

	test_src, capture_ok, capture_err := export_capture_test(s, predicate, capture, allocator)
	if !capture_ok {
		return Verification {
			passed = true,
			reason = fmt.aprintf("pass; regression not captured: %s", capture_err, allocator = allocator),
		}
	}
	return Verification{passed = true, reason = "pass", captured = true, test_src = test_src}
}

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

@(private = "file")
response_error_object :: proc(object: json.Object, allocator := context.allocator) -> string {
	if text, has_error := object["error"].(json.String); has_error {
		return strings.clone(string(text), allocator)
	}
	return "command refused without an error message"
}

@(private = "file")
json_quote :: proc(text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write_json_string(&b, text)
	return strings.to_string(b)
}

@(private = "file")
field_value_text :: proc(value: Field_Value, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	render_field_value_text(&b, value)
	return strings.to_string(b)
}
