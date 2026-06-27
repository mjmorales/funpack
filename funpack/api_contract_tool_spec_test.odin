package funpack

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"

CONTRACT_REL :: "../contract/funpack-api.json"

contract_path :: proc() -> string {
	resolved, _ := filepath.join({#directory, CONTRACT_REL}, context.temp_allocator)
	return resolved
}

Expected_Tool :: struct {
	name:           string,
	command:        string,
	group:          string,
	class:          string,
	session_scoped: bool,
	arg_names:      []string,
}

project_tool_name :: proc(prefix, command: string, allocator := context.allocator) -> string {
	if prefix == "" {
		return command
	}
	return concat3(prefix, "_", command, allocator)
}

concat3 :: proc(a, b, c: string, allocator := context.allocator) -> string {
	out := make([]byte, len(a) + len(b) + len(c), allocator)
	copy(out[:], a)
	copy(out[len(a):], b)
	copy(out[len(a) + len(b):], c)
	return string(out)
}

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

committed_tool_arg_names :: proc(spec: Tool_Spec, allocator := context.allocator) -> []string {
	names := make([]string, len(spec.args), allocator)
	for arg, i in spec.args {
		names[i] = arg.name
	}
	slice.sort(names)
	return names
}

find_expected :: proc(tools: []Expected_Tool, command: string) -> (Expected_Tool, bool) {
	for tool in tools {
		if tool.command == command {
			return tool, true
		}
	}
	return {}, false
}

@(test)
test_tool_specs_match_contract :: proc(t: ^testing.T) {
	a := context.temp_allocator
	expected, ok := walk_contract_tools(t, a)
	if !ok {
		return
	}

	testing.expectf(
		t,
		len(TOOL_SPECS) == len(expected),
		"TOOL_SPECS has %d tools, the contract walk projects %d — regenerate api_contract.gen.odin",
		len(TOOL_SPECS),
		len(expected),
	)

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

@(test)
test_every_tool_spec_arg_is_typed :: proc(t: ^testing.T) {
	valid_types := []string{"string", "integer", "number", "boolean", "array", "object"}
	for spec in TOOL_SPECS {
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

SERVER_NATIVE_TOOLS :: []string{
	"build", "export", "check", "test", "fmt",
	"warden_find", "warden_graph", "warden_holes", "warden_probes", "warden_debt", "warden_tags", "warden_pipeline",
	"docs_get", "docs_search", "health",
	"record",
	"session_start", "session_list", "session_end",
}

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
