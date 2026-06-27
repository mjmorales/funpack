package main

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(private = "file")
ctrl_stage_fixture :: proc(name: string) -> (path: string, ok: bool) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	path, _ = filepath.join({base, name}, context.temp_allocator)
	if write_err := os.write_entire_file(path, SESSION_FIXTURE); write_err != nil {
		return "", false
	}
	return path, true
}

@(private = "file")
ctrl_dispatch_tool :: proc(
	registry: ^Mcp_Session_Registry,
	tool_name: string,
	args_json: string,
) -> (
	result: string,
	handled: bool,
) {
	spec, found := mcp_lookup_tool(tool_name)
	if !found {
		return "", false
	}
	arguments: json.Object
	parsed, err := json.parse(transmute([]u8)args_json, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err == .None {
		if object, is_object := parsed.(json.Object); is_object {
			arguments = object
		}
	}
	dispatch := Mcp_Dispatch {
		spec      = spec,
		name      = tool_name,
		arguments = arguments,
		id        = Mcp_Id{kind = .Integer, integer = 7},
		registry  = registry,
	}
	return mcp_control_dispatch(dispatch, context.temp_allocator)
}

@(test)
test_ctrl_family_claims_exactly_its_tools :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	for tool in ctrl_family_tools {
		_, handled := ctrl_dispatch_tool(&registry, tool, `{"session_id":"sess-absent"}`)
		testing.expect(t, handled, "the control family claims its own tool")
	}

	other_family := [?]string{"build", "docs_search", "session_start", "inspect_pipeline", "inspect_screenshot"}
	for other in other_family {
		spec, found := mcp_lookup_tool(other)
		if !found {
			continue
		}
		dispatch := Mcp_Dispatch{spec = spec, name = other, id = Mcp_Id{kind = .Integer, integer = 1}, registry = &registry}
		_, handled := mcp_control_dispatch(dispatch, context.temp_allocator)
		testing.expect(t, !handled, "the control family declines a tool another family owns")
	}
}

@(test)
test_ctrl_tool_command_matches_generated_spec :: proc(t: ^testing.T) {
	testing.expect(t, ctrl_assert_specs_present(), "every control family tool is a generated Tool_Spec")
	for tool in ctrl_family_tools {
		command, has := ctrl_tool_command(tool)
		testing.expect(t, has, "the family resolves its own tool's command")
		spec, found := mcp_lookup_tool(tool)
		testing.expect(t, found, "the tool is in TOOL_SPECS")
		testing.expect_value(t, command, spec.command)
	}
}

@(test)
test_ctrl_missing_session_id_is_invalid_input :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	result, handled := ctrl_dispatch_tool(&registry, "control_branch", `{}`)
	testing.expect(t, handled, "the family claims control_branch even when session_id is missing")
	testing.expect(t, strings.contains(result, `"result":`), "the refusal is a JSON-RPC result, not an error object")
	testing.expect(t, !strings.contains(result, `"error":{"code"`), "no JSON-RPC error object for a domain refusal")
	testing.expect(t, strings.contains(result, `"isError":true`), "a missing session_id is an IsError result")
	testing.expect(t, strings.contains(result, `\"category\":\"invalid_input\"`), "keyed invalid_input")
}

@(test)
test_ctrl_stale_session_is_session_error :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	result, handled := ctrl_dispatch_tool(&registry, "control_spawn", `{"session_id":"sess-404","thing":"Hero"}`)
	testing.expect(t, handled, "the family claims control_spawn")
	testing.expect(t, strings.contains(result, `"isError":true`), "a stale session is an IsError result")
	testing.expect(t, strings.contains(result, `\"category\":\"session\"`), "keyed session")
}

@(test)
test_ctrl_branch_forks_non_warranted :: proc(t: ^testing.T) {
	path, staged := ctrl_stage_fixture("funpack-mcp-ctrl-branch.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, _ := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	if id == "" {
		return
	}

	result, handled := ctrl_dispatch_tool(&registry, "control_branch", ctrl_session_args(id, ``))
	testing.expect(t, handled, "control_branch is claimed")
	testing.expect(t, strings.contains(result, `"isError":false`), "a clean fork is not an error")
	testing.expect(t, strings.contains(result, `\"ok\":true`), "the lifted §28 envelope reports ok")
	testing.expect(t, strings.contains(result, `\"warranted\":false`), "a control branch is never warranted (§28 §2)")
	testing.expect(t, strings.contains(result, `\"branch\":`), "the branch position is surfaced")
}

@(test)
test_ctrl_spawn_returns_minted_instance :: proc(t: ^testing.T) {
	path, staged := ctrl_stage_fixture("funpack-mcp-ctrl-spawn.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, _ := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	if id == "" {
		return
	}

	result, _ := ctrl_dispatch_tool(&registry, "control_spawn", ctrl_session_args(id, `"thing":"Hero"`))
	testing.expect(t, strings.contains(result, `"isError":false`), "a clean spawn is not an error")
	testing.expect(t, strings.contains(result, `\"instance\":`), "spawn surfaces the minted instance id")
	testing.expect(t, strings.contains(result, `\"warranted\":false`), "spawn forks — never warranted")
}

@(test)
test_ctrl_set_int_arg_round_trips :: proc(t: ^testing.T) {
	path, staged := ctrl_stage_fixture("funpack-mcp-ctrl-set.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, _ := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	if id == "" {
		return
	}

	result, _ := ctrl_dispatch_tool(
		&registry,
		"control_set",
		ctrl_session_args(id, `"thing":"Hero","instance":0,"field":"pos","value":"4"`),
	)
	testing.expect(t, strings.contains(result, `"isError":false`), "the int instance arg round-tripped (set found the row)")
	testing.expect(t, strings.contains(result, `\"ok\":true`), "the forced column committed on the branch")
}

@(test)
test_ctrl_checkout_flips_active_lineage :: proc(t: ^testing.T) {
	path, staged := ctrl_stage_fixture("funpack-mcp-ctrl-checkout.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, _ := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	if id == "" {
		return
	}

	forked, _ := ctrl_dispatch_tool(&registry, "control_branch", ctrl_session_args(id, ``))
	testing.expect(t, strings.contains(forked, `"isError":false`), "the branch forks before checkout")

	result, _ := ctrl_dispatch_tool(&registry, "control_checkout", ctrl_session_args(id, ``))
	testing.expect(t, strings.contains(result, `"isError":false`), "checkout of a live branch succeeds")
	testing.expect(t, strings.contains(result, `\"active\":\"branch\"`), "checkout flips the active lineage to the branch")
}

@(test)
test_ctrl_checkout_without_branch_refuses :: proc(t: ^testing.T) {
	path, staged := ctrl_stage_fixture("funpack-mcp-ctrl-checkout-empty.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, _ := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	if id == "" {
		return
	}

	result, _ := ctrl_dispatch_tool(&registry, "control_checkout", ctrl_session_args(id, ``))
	testing.expect(t, strings.contains(result, `"isError":true`), "checkout with no branch refuses")
	testing.expect(t, strings.contains(result, `\"category\":\"refused\"`), "a resolved-but-refused control command is keyed refused, not session")
}

@(test)
test_ctrl_audit_folds_clean :: proc(t: ^testing.T) {
	path, staged := ctrl_stage_fixture("funpack-mcp-ctrl-audit.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, _ := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	if id == "" {
		return
	}

	result, handled := ctrl_dispatch_tool(&registry, "audit", ctrl_session_args(id, ``))
	testing.expect(t, handled, "audit is claimed by the control + self-heal family")
	testing.expect(t, strings.contains(result, `"isError":false`), "audit folds clean on a fresh session")
	testing.expect(t, strings.contains(result, `\"cmd\":\"audit\"`), "the lifted §28 envelope is the audit response")
}

@(test)
test_ctrl_capture_test_folds :: proc(t: ^testing.T) {
	path, staged := ctrl_stage_fixture("funpack-mcp-ctrl-capture.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, _ := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	if id == "" {
		return
	}

	result, handled := ctrl_dispatch_tool(&registry, "capture_test", ctrl_session_args(id, `"behavior":"advance","tick":5`))
	testing.expect(t, handled, "capture_test is claimed")
	testing.expect(t, strings.contains(result, `\"cmd\":\"capture_test\"`), "the lifted envelope is the capture_test response")
}

@(private = "file")
ctrl_chain_call :: proc(
	t: ^testing.T,
	registry: ^Mcp_Session_Registry,
	name: string,
	args_json: string,
) -> string {
	params := make(json.Object, context.temp_allocator)
	params["name"] = json.String(name)
	parsed, err := json.parse(transmute([]u8)args_json, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	testing.expectf(t, err == .None, "chain args must parse: %v", err)
	object, is_object := parsed.(json.Object)
	testing.expect(t, is_object, "chain args must be a JSON object")
	params["arguments"] = object
	request := Mcp_Request{id = Mcp_Id{kind = .Integer, integer = 11}, method = "tools/call", params = params}
	return mcp_handle_tools_call(registry, request, context.temp_allocator)
}

@(test)
test_ctrl_spawn_after_rewind_anchors_at_cursor :: proc(t: ^testing.T) {
	path, staged := ctrl_stage_fixture("funpack-mcp-ctrl-rewind-spawn.fpk")
	if !staged {
		return
	}
	defer os.remove(path)

	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)
	id, open_result := mcp_session_registry_open(&registry, path, "", false, "", context.temp_allocator)
	if open_result != .Ok || id == "" {
		return
	}

	sid := strings.concatenate({`"session_id":"`, id, `"`}, context.temp_allocator)

	_ = ctrl_chain_call(t, &registry, "time_load", strings.concatenate({"{", sid, "}"}, context.temp_allocator))
	_ = ctrl_chain_call(t, &registry, "time_run", strings.concatenate({"{", sid, "}"}, context.temp_allocator))
	rewind_result := ctrl_chain_call(t, &registry, "time_rewind", strings.concatenate({"{", sid, `,"tick":2}`}, context.temp_allocator))
	testing.expect(t, strings.contains(rewind_result, `"isError":false`), "the rewind to an interior tick is clean")
	testing.expect(t, strings.contains(rewind_result, `\"tick\":2`), "the cursor rewinds to tick 2")

	spawn_result := ctrl_chain_call(t, &registry, "control_spawn", strings.concatenate({"{", sid, `,"thing":"Hero"}`}, context.temp_allocator))
	testing.expect(t, strings.contains(spawn_result, `"isError":false`), "the post-rewind spawn is clean")
	testing.expect(t, strings.contains(spawn_result, `\"base_tick\":2`), "the implicit fork anchors at the rewound cursor (tick 2), NOT the recording end")
	testing.expect(t, strings.contains(spawn_result, `\"instance\":`), "the spawn surfaces the minted instance id")

	inspect_result := ctrl_chain_call(t, &registry, "inspect_state", strings.concatenate({"{", sid, `,"thing":"Hero","branch":"branch","tick":2}`}, context.temp_allocator))
	testing.expect(t, strings.contains(inspect_result, `"isError":false`), "the spawned state is a clean read at the cursor tick")
	testing.expect(t, strings.contains(inspect_result, `\"instances\":[{`), "the spawned Hero is observable at the rewound tick — the edit anchors at the cursor, not off at the recording end")
}

@(private = "file")
ctrl_session_args :: proc(session_id: string, extra: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"session_id":"`)
	strings.write_string(&b, session_id)
	strings.write_byte(&b, '"')
	if extra != "" {
		strings.write_byte(&b, ',')
		strings.write_string(&b, extra)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}
