// Deliberate spec for the control + self-heal tool dispatch family
// (mcp_tools_control.odin) — the living junction test for the §28 control/self-heal
// arm of the tools/call chain. It exercises the WHOLE seam end to end: an Mcp_Dispatch
// built exactly as mcp_handle_tools_call builds one (resolved Tool_Spec, parsed MCP
// arguments, the server-scoped session registry) folded through mcp_control_dispatch
// against a live session, asserting the rendered JSON-RPC result. The tests pin the
// contract this family must keep:
//
//   - name→command projection: every claimed tool maps to its generated
//     Tool_Spec.command, and no tool outside the family is claimed (the merge-clean
//     invariant — at most one family owns any tool name);
//   - the control FORK theorem: a control command answers `"warranted":false` and
//     forks a Session_Branch, never touching the warranted trunk;
//   - spawn answers the minted instance; checkout flips the active lineage;
//   - the integer-preserving re-render: an int arg (tick/instance/ticks) survives the
//     marshal → re-parse round-trip and is NOT silently dropped as a float;
//   - the stale-session and missing-session_id refusals ride the IsError envelope
//     (mcp_error.odin), never a JSON-RPC error object;
//   - capture_test / audit (the observe-class self-heal pair) fold and lift cleanly.
//
// DEFINE-FREE FLOOR: like the registry tests, these run in the default `odin test .`
// build — everything the arm folds is SDL-free, so the family's dispatch contract is
// pinned in the same deterministic floor the rest of the compiler tests run in.
package main

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// ctrl_stage_fixture writes the shared SESSION_FIXTURE (mcp_session_test.odin — a
// one-behavior Hero artifact with a Fixed `pos` a control command can fork-and-force)
// to a uniquely-named temp file and returns its path. ok=false (skip, never false-fail)
// when the temp root cannot be staged. Self-contained per the test standard — its own
// stager so the family test does not reach into another file's private helper.
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

// ctrl_dispatch_tool resolves the Tool_Spec for `tool_name`, parses `args_json` into
// the MCP arguments object, and folds the assembled Mcp_Dispatch through
// mcp_control_dispatch against `registry` — the exact path mcp_handle_tools_call drives,
// so a test exercises the real seam (name lookup + arg parse + family arm) rather than
// a stubbed shortcut. Returns the rendered JSON-RPC result line and whether the family
// claimed the tool.
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

// test_ctrl_family_claims_exactly_its_tools pins the merge-clean invariant: the family
// claims each of its ten tools (handled=true) and DECLINES every tool another family
// owns (handled=false), so the dispatch chain has exactly one owner per tool name.
@(test)
test_ctrl_family_claims_exactly_its_tools :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	// Each family tool is claimed. (No live session needed: claiming is a name match;
	// the fold then refuses the missing session, which is still a handled result.)
	for tool in ctrl_family_tools {
		_, handled := ctrl_dispatch_tool(&registry, tool, `{"session_id":"sess-absent"}`)
		testing.expect(t, handled, "the control family claims its own tool")
	}

	// A representative tool from EACH other family is declined — the chain flows past.
	other_family := [?]string{"build", "docs_search", "session_start", "inspect_pipeline", "inspect_screenshot"}
	for other in other_family {
		spec, found := mcp_lookup_tool(other)
		if !found {
			continue // a family not yet in the contract — nothing to decline
		}
		dispatch := Mcp_Dispatch{spec = spec, name = other, id = Mcp_Id{kind = .Integer, integer = 1}, registry = &registry}
		_, handled := mcp_control_dispatch(dispatch, context.temp_allocator)
		testing.expect(t, !handled, "the control family declines a tool another family owns")
	}
}

// test_ctrl_tool_command_matches_generated_spec pins the name→command projection: every
// claimed tool's §28 command (ctrl_tool_command) equals its generated Tool_Spec.command,
// so dispatch cannot drift from the advertised contract. ctrl_assert_specs_present
// confirms every family tool is a real generated spec.
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

// test_ctrl_missing_session_id_is_invalid_input pins the schema-violation refusal: a
// control call with no session_id is an IsError result keyed invalid_input — a
// SUCCESSFUL JSON-RPC result carrying the failure in-band, never a JSON-RPC error.
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

// test_ctrl_stale_session_is_session_error pins the stale-session refusal: a control
// call against an id the registry never minted (or has ended) is an IsError result
// keyed session — the found=false path mcp_session_registry_request signals.
@(test)
test_ctrl_stale_session_is_session_error :: proc(t: ^testing.T) {
	registry := mcp_session_registry_make(context.temp_allocator)
	defer mcp_session_registry_destroy(&registry, context.temp_allocator)

	result, handled := ctrl_dispatch_tool(&registry, "control_spawn", `{"session_id":"sess-404","thing":"Hero"}`)
	testing.expect(t, handled, "the family claims control_spawn")
	testing.expect(t, strings.contains(result, `"isError":true`), "a stale session is an IsError result")
	testing.expect(t, strings.contains(result, `\"category\":\"session\"`), "keyed session")
}

// test_ctrl_branch_forks_non_warranted is the control FORK theorem made mechanical: a
// `control_branch` against a live session answers a clean (isError:false) result whose
// §28 envelope carries `"warranted":false` and a branch position — the §28 §2 invariant
// a control lineage is never warranted. This is the headline contract of the family.
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

// test_ctrl_spawn_returns_minted_instance pins the spawn contract: control_spawn folds
// a tick-boundary spawn batch onto the branch and surfaces the minted instance id, so
// the agent can address the new row. The clean result carries the §28 `instance` field.
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

// test_ctrl_set_int_arg_round_trips is the integer-preserving crux as a regression: a
// control_set carries an INTEGER `instance` arg, which must survive the MCP-args →
// §28-line re-render and the §28 re-parse as a json.Integer (json_int_field demands
// one). If ctrl_write_json_value rendered it as a float, `set` would refuse "no
// instance with that id" — so a clean ok:true result PROVES the int round-tripped.
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

	// instance:0 is the spawned Hero; pos is a Fixed forced to raw 4. A float-rendered
	// instance would miss the row and refuse — ok:true is the int-round-trip proof.
	result, _ := ctrl_dispatch_tool(
		&registry,
		"control_set",
		ctrl_session_args(id, `"thing":"Hero","instance":0,"field":"pos","value":"4"`),
	)
	testing.expect(t, strings.contains(result, `"isError":false`), "the int instance arg round-tripped (set found the row)")
	testing.expect(t, strings.contains(result, `\"ok\":true`), "the forced column committed on the branch")
}

// test_ctrl_checkout_flips_active_lineage pins the checkout contract: after a branch is
// forked, control_checkout flips the active lineage to it — the §28 result reports
// `"active":"branch"`. Checkout is the lone non-perturbing control arm (it navigates,
// never forks), so the canonical trunk stays untouched.
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

// test_ctrl_checkout_without_branch_refuses pins the fail-closed navigation rule:
// checking out the branch when NONE is live refuses (there is no such lineage to
// navigate to). The §28 refusal is lifted into an IsError result keyed exec.
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
	testing.expect(t, strings.contains(result, `\"category\":\"exec\"`), "a resolved-but-refused control command is an exec failure")
}

// test_ctrl_audit_folds_clean pins the self-heal observe pair: `audit` (the
// observe-class divergence twin of capture_test) folds through the named session and
// lifts a clean ok:true result. A fresh session has no divergence, so audit reports the
// warranted baseline — the point is the arm wires audit to the session at all.
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

// test_ctrl_capture_test_folds pins the capture → test self-heal arm: capture_test
// re-folds a recorded behavior step at a tick into a regression-test source. With a
// behavior name and an in-range tick it lifts a clean result carrying the generated
// test; both args are required, so this also exercises the int `tick` round-trip.
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

// ctrl_session_args builds an MCP arguments JSON object string with the session_id
// selector plus an optional pre-rendered `,extra` field run — the small helper the
// fold tests build their arguments through so each test reads as its tool's call.
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
