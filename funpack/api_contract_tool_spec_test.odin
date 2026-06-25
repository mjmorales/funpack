package funpack

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"

// The contract pin/staleness guard — a pure, SDL-free test. The funpack<->MCP
// contract (contract/funpack-api.json) is the single source of truth; the generated
// TOOL_SPECS table in api_contract.gen.odin is a MECHANICAL projection of BOTH its
// tool sections — the §28 introspect.command_groups (session-scoped wire commands)
// AND server_tools (the server-native compute / docs / session-lifecycle tools).
// These tests walk the contract FRESH, projecting each section by the SAME rules the
// generator applies, and assert the committed table matches that walk exactly in
// BOTH drift directions, so the table cannot silently drift from the contract — the
// drift guard the generated-tools/list approach depends on. A contract edit that
// lands without a regenerate, or a hand-edit of the generated file, trips a loud
// failure here.

// CONTRACT_REL is contract/funpack-api.json relative to the repo root; the funpack
// package dir sits one level under the root, so #directory resolves it absolutely
// (a bare `odin test .` from any cwd, and any worktree, finds the same file).
CONTRACT_REL :: "../contract/funpack-api.json"

contract_path :: proc() -> string {
	resolved, _ := filepath.join({#directory, CONTRACT_REL}, context.temp_allocator)
	return resolved
}

// expected_tool is the fresh-walk projection of one contract tool into the shape
// the generator emits: the advertised tool name, the command/group/class dispatch
// hints, whether the tool is session-scoped, and the full input_schema arg name set
// (a §28 command projects session_id + wire args + mcp_args + branch for observe; a
// server-native tool projects its args verbatim). The test compares the committed
// TOOL_SPECS entry against this.
Expected_Tool :: struct {
	name:           string,
	command:        string,
	group:          string,
	class:          string,
	session_scoped: bool,
	arg_names:      []string,
}

// project_tool_name mirrors the generator's group.tool_prefix projection: a
// non-empty prefix yields "<prefix>_<command>", an empty prefix the bare command.
project_tool_name :: proc(prefix, command: string, allocator := context.allocator) -> string {
	if prefix == "" {
		return command
	}
	return concat3(prefix, "_", command, allocator)
}

// concat3 joins three strings — a tiny local helper so the projection reads as one
// expression without pulling strings.concatenate's variadic at every call site.
concat3 :: proc(a, b, c: string, allocator := context.allocator) -> string {
	out := make([]byte, len(a) + len(b) + len(c), allocator)
	copy(out[:], a)
	copy(out[len(a):], b)
	copy(out[len(a) + len(b):], c)
	return string(out)
}

// walk_contract_tools parses contract/funpack-api.json and projects every contract
// tool — both the §28 introspect.command_groups commands and the server_tools
// server-native tools — into an Expected_Tool, applying the SAME rules the
// generator applies. The arg name set is returned SORTED so it compares
// order-independently against the committed table.
walk_contract_tools :: proc(t: ^testing.T, allocator := context.allocator) -> (tools: []Expected_Tool, ok: bool) {
	raw, read_err := os.read_entire_file_from_path(contract_path(), allocator)
	if read_err != nil {
		testing.fail_now(t, "cannot read contract/funpack-api.json")
	}

	value, parse_err := json.parse(raw, allocator = allocator)
	if parse_err != nil {
		testing.fail_now(t, "contract/funpack-api.json is not valid JSON")
	}

	root, is_obj := value.(json.Object)
	if !is_obj {
		testing.fail_now(t, "contract root is not an object")
	}

	out := make([dynamic]Expected_Tool, allocator)
	walk_introspect_commands(t, root, &out, allocator)
	walk_server_tools(t, root, &out, allocator)
	return out[:], true
}

// walk_introspect_commands projects every §28 introspect.command_groups command
// into an Expected_Tool, applying the generator's §28 rules: the per-group
// tool_prefix, the universal session_id arg first, the per-command wire args, any
// MCP-render-only mcp_args, and a trailing branch arg for every observe-class command
// (the committed table emits session_id first, sorted wire args + mcp_args, branch
// last — a different order but the same set; the test compares as sets). Every §28
// command is session-scoped.
walk_introspect_commands :: proc(t: ^testing.T, root: json.Object, out: ^[dynamic]Expected_Tool, allocator := context.allocator) {
	introspect, has_introspect := root["introspect"].(json.Object)
	if !has_introspect {
		testing.fail_now(t, "contract has no introspect object")
	}
	groups, has_groups := introspect["command_groups"].(json.Object)
	if !has_groups {
		testing.fail_now(t, "contract has no command_groups object")
	}

	for group_name, group_value in groups {
		if group_name == "$comment" {
			continue
		}
		group, group_is_obj := group_value.(json.Object)
		if !group_is_obj {
			testing.fail_now(t, "command_groups entry is not an object")
		}
		class, _ := group["class"].(json.String)
		prefix, _ := group["tool_prefix"].(json.String)
		commands, has_commands := group["commands"].(json.Array)
		if !has_commands {
			testing.fail_now(t, "command_groups group has no commands array")
		}

		for command_value in commands {
			command, command_is_obj := command_value.(json.Object)
			if !command_is_obj {
				testing.fail_now(t, "a command entry is not an object")
			}
			command_name, _ := command["name"].(json.String)

			names := make([dynamic]string, allocator)
			append(&names, "session_id")
			if args, has_args := command["args"].(json.Object); has_args {
				for arg_name in args {
					if arg_name == "$comment" {
						continue
					}
					append(&names, arg_name)
				}
			}
			// MCP-render-only args (mcp_args) project into the tool input_schema too —
			// they ride the same superset as the wire args (the generator emits them
			// after args, before branch). Optional: most commands have none.
			if mcp_args, has_mcp := command["mcp_args"].(json.Object); has_mcp {
				for arg_name in mcp_args {
					if arg_name == "$comment" {
						continue
					}
					append(&names, arg_name)
				}
			}
			if class == "observe" {
				append(&names, "branch")
			}
			arg_names := names[:]
			slice.sort(arg_names)

			append(out, Expected_Tool{
				name = project_tool_name(string(prefix), string(command_name), allocator),
				command = string(command_name),
				group = string(group_name),
				class = string(class),
				session_scoped = true,
				arg_names = arg_names,
			})
		}
	}
}

// walk_server_tools projects every server_tools tool into an Expected_Tool,
// applying the generator's server-native rules: the tool name IS its command (no
// §28 wire command), its declaring FAMILY is its group, the family's class is its
// class, the family's session_scoped flag carries through, and its args are its full
// input_schema verbatim — NO injected session_id or branch arg (those are
// §28-specific). server_tools is OPTIONAL: a contract without it walks only the §28
// section, so this is a no-op then.
walk_server_tools :: proc(t: ^testing.T, root: json.Object, out: ^[dynamic]Expected_Tool, allocator := context.allocator) {
	server_tools, has_server_tools := root["server_tools"].(json.Object)
	if !has_server_tools {
		return
	}
	families, has_families := server_tools["families"].(json.Object)
	if !has_families {
		testing.fail_now(t, "server_tools has no families object")
	}

	for family_name, family_value in families {
		if family_name == "$comment" {
			continue
		}
		family, family_is_obj := family_value.(json.Object)
		if !family_is_obj {
			testing.fail_now(t, "server_tools families entry is not an object")
		}
		class, _ := family["class"].(json.String)
		session_scoped, _ := family["session_scoped"].(json.Boolean)
		tools, has_tools := family["tools"].(json.Array)
		if !has_tools {
			testing.fail_now(t, "server_tools family has no tools array")
		}

		for tool_value in tools {
			tool, tool_is_obj := tool_value.(json.Object)
			if !tool_is_obj {
				testing.fail_now(t, "a server_tools tool entry is not an object")
			}
			tool_name, _ := tool["name"].(json.String)

			names := make([dynamic]string, allocator)
			if args, has_args := tool["args"].(json.Object); has_args {
				for arg_name in args {
					if arg_name == "$comment" {
						continue
					}
					append(&names, arg_name)
				}
			}
			arg_names := names[:]
			slice.sort(arg_names)

			append(out, Expected_Tool{
				name = string(tool_name),
				command = string(tool_name),
				group = string(family_name),
				class = string(class),
				session_scoped = bool(session_scoped),
				arg_names = arg_names,
			})
		}
	}
}

// committed_tool_arg_names returns the SORTED arg name set of one committed
// Tool_Spec, so it compares order-independently against the fresh walk.
committed_tool_arg_names :: proc(spec: Tool_Spec, allocator := context.allocator) -> []string {
	names := make([]string, len(spec.args), allocator)
	for arg, i in spec.args {
		names[i] = arg.name
	}
	slice.sort(names)
	return names
}

// find_expected returns the fresh-walk tool with the given command name (commands
// are globally unique in the §28 closed set, so the command name is the join key).
find_expected :: proc(tools: []Expected_Tool, command: string) -> (Expected_Tool, bool) {
	for tool in tools {
		if tool.command == command {
			return tool, true
		}
	}
	return {}, false
}

// test_tool_specs_match_contract is the staleness gate: the committed TOOL_SPECS table
// must be the exact projection of the fresh contract walk. It catches both drift
// directions — a contract command the table lacks, and a table entry no contract
// command backs — plus every per-tool field (name, group, class) and the full
// input_schema arg set. A contract edit without a regenerate fails here.
@(test)
test_tool_specs_match_contract :: proc(t: ^testing.T) {
	a := context.temp_allocator
	expected, ok := walk_contract_tools(t, a)
	if !ok {
		return
	}

	// 1:1 cardinality — every contract command projects to exactly one Tool_Spec.
	testing.expectf(
		t,
		len(TOOL_SPECS) == len(expected),
		"TOOL_SPECS has %d tools, the contract walk projects %d — regenerate api_contract.gen.odin",
		len(TOOL_SPECS),
		len(expected),
	)

	// Every committed entry must back onto a contract command, field-for-field.
	for spec in TOOL_SPECS {
		exp, found := find_expected(expected, spec.command)
		if !testing.expectf(t, found, "TOOL_SPECS command %q is absent from the contract — stale generated table", spec.command) {
			continue
		}
		testing.expectf(t, spec.name == exp.name, "tool %q: name %q != contract projection %q", spec.command, spec.name, exp.name)
		testing.expectf(t, spec.group == exp.group, "tool %q: group %q != contract %q", spec.command, spec.group, exp.group)
		testing.expectf(t, spec.class == exp.class, "tool %q: class %q != contract %q", spec.command, spec.class, exp.class)
		testing.expectf(t, spec.session_scoped == exp.session_scoped, "tool %q: session_scoped %t != contract %t", spec.command, spec.session_scoped, exp.session_scoped)

		got_args := committed_tool_arg_names(spec, a)
		testing.expectf(
			t,
			slice.equal(got_args, exp.arg_names),
			"tool %q: input_schema args %v != contract projection %v — schema drifted from the wire arg shape",
			spec.command,
			got_args,
			exp.arg_names,
		)
	}

	// Every contract command must have a committed entry (catches a contract
	// command the regenerate would add that the committed table is missing).
	for exp in expected {
		found := false
		for spec in TOOL_SPECS {
			if spec.command == exp.command {
				found = true
				break
			}
		}
		testing.expectf(t, found, "contract command %q has no TOOL_SPECS entry — regenerate api_contract.gen.odin", exp.command)
	}
}

// TestEveryToolSpecArgIsTyped pins that every projected arg carries a non-empty
// JSON-Schema type and description — the schema-completeness floor a tools/list
// consumer relies on (an arg with a blank type or doc is a malformed input_schema
// property). For a session-scoped (§28) tool the generator's injected session_id is
// always the first arg; a server-native tool carries no injected handle and may take
// no args at all (health, session_list), so that lead assertion is gated on
// session_scoped.
@(test)
test_every_tool_spec_arg_is_typed :: proc(t: ^testing.T) {
	valid_types := []string{"string", "integer", "number", "boolean", "array", "object"}
	for spec in TOOL_SPECS {
		// The session handle is always the first arg of a session-scoped (§28) tool.
		if spec.session_scoped {
			testing.expectf(t, len(spec.args) >= 1 && spec.args[0].name == "session_id",
				"session-scoped tool %q must lead its input_schema with session_id", spec.command)
		}
		for arg in spec.args {
			testing.expectf(t, arg.name != "", "tool %q has an arg with an empty name", spec.command)
			testing.expectf(t, arg.doc != "", "tool %q arg %q has an empty doc", spec.command, arg.name)
			testing.expectf(
				t,
				slice.contains(valid_types, arg.json_type),
				"tool %q arg %q has non-JSON-Schema type %q",
				spec.command,
				arg.name,
				arg.json_type,
			)
		}
	}
}

// test_tool_specs_cover_every_command_const pins the §28 SUBSET of the Tool_Spec
// table against the generated CMD_* name surface in the SAME file: every CMD_*
// constant must be the command of exactly one session-scoped Tool_Spec, AND the
// count of CMD_* consts equals the count of session-scoped tools, so the two
// generated projections of the §28 command set (the name consts and the §28 slice of
// the unified tool table) can never disagree. The server-native tools live in the
// same table but carry no CMD_* const (they have no §28 wire command), so this test
// scopes its cardinality check to the session-scoped subset.
@(test)
test_tool_specs_cover_every_command_const :: proc(t: ^testing.T) {
	command_consts := []string{
		CMD_LOAD, CMD_RUN, CMD_PAUSE, CMD_STEP, CMD_REWIND, CMD_RESET, CMD_STATUS,
		CMD_BREAK, CMD_WATCH, CMD_CLEAR,
		CMD_SIGNALS, CMD_PIPELINE, CMD_TRACE, CMD_DIFF, CMD_REPLAY_BEHAVIOR, CMD_DRAW_LIST, CMD_STATE, CMD_SCREENSHOT,
		CMD_INJECT_INPUT, CMD_SET, CMD_SPAWN, CMD_DESPAWN, CMD_EMIT, CMD_RELOAD, CMD_BRANCH, CMD_CHECKOUT,
		CMD_CAPTURE_TEST, CMD_CAPTURE_TICK, CMD_AUDIT,
	}
	session_scoped_count := 0
	for spec in TOOL_SPECS {
		if spec.session_scoped {
			session_scoped_count += 1
		}
	}
	testing.expectf(
		t,
		len(command_consts) == session_scoped_count,
		"%d CMD_* command consts but %d session-scoped Tool_Specs — the two §28 projections diverged",
		len(command_consts),
		session_scoped_count,
	)
	for cmd in command_consts {
		found := false
		for spec in TOOL_SPECS {
			if spec.command == cmd && spec.session_scoped {
				found = true
				break
			}
		}
		testing.expectf(t, found, "command const %q has no session-scoped Tool_Spec", cmd)
	}
}

// SERVER_NATIVE_TOOLS is the closed set of server-native tool names the contract's
// server_tools section declares — the oneshot / docs_health / record / session families.
// It is the deliberate floor those families dispatch against: every one must be present
// in TOOL_SPECS as a NON-session-scoped tool for tools/list to advertise it and
// mcp_lookup_tool to resolve it. Adding a server-native tool means declaring it in
// the contract, regenerating, and extending this list.
SERVER_NATIVE_TOOLS :: []string{
	"build", "export", "check", "test", "fmt",
	"warden_find", "warden_graph", "warden_holes", "warden_probes", "warden_debt", "warden_tags", "warden_pipeline",
	"docs_get", "docs_search", "health",
	"record",
	"session_start", "session_list", "session_end",
}

// test_tool_specs_cover_every_server_native_tool pins that every server-native tool
// the contract declares is present in the unified TOOL_SPECS table as a non-session-
// scoped entry. Without it, mcp_lookup_tool and mcp_handle_tools_list cannot reach or
// advertise the oneshot / docs-health / session-lifecycle families. The count is
// pinned too, so a contract edit that drops a server-native tool (or a hand-edit of
// the table) trips here.
@(test)
test_tool_specs_cover_every_server_native_tool :: proc(t: ^testing.T) {
	server_native_count := 0
	for spec in TOOL_SPECS {
		if !spec.session_scoped {
			server_native_count += 1
		}
	}
	testing.expectf(
		t,
		len(SERVER_NATIVE_TOOLS) == server_native_count,
		"%d declared server-native tools but %d non-session-scoped Tool_Specs — regenerate api_contract.gen.odin or update SERVER_NATIVE_TOOLS",
		len(SERVER_NATIVE_TOOLS),
		server_native_count,
	)
	for name in SERVER_NATIVE_TOOLS {
		found := false
		for spec in TOOL_SPECS {
			if spec.name == name && !spec.session_scoped {
				found = true
				break
			}
		}
		testing.expectf(t, found, "server-native tool %q has no non-session-scoped Tool_Spec — the family is unreachable", name)
	}
}
