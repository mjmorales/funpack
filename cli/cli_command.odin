package cli

import "core:fmt"
import "core:slice"
import "core:strings"

Cli_Flag_Kind :: enum {
	Bool,
	String,
	Int,
}

Cli_Flag_Value :: union {
	bool,
	string,
	int,
}

Cli_Flag_Validate :: #type proc(value: string) -> bool

Cli_Flag :: struct {
	name:      string,
	shorthand: rune,
	kind:      Cli_Flag_Kind,
	usage:     string,
	default:   Cli_Flag_Value,
	required:  bool,
	validate:  Cli_Flag_Validate,
}

// The verb owns its {0,1,2} exit code; the framework only relays it, never exits.
Cli_Run :: #type proc(inv: ^Cli_Invocation) -> int

Cli_Validate :: #type proc(inv: ^Cli_Invocation) -> bool

Cli_Command :: struct {
	use:         string,
	short:       string,
	long:        string,
	flags:       []Cli_Flag,
	args:        Cli_Args,
	run:         Cli_Run,
	validate:    Cli_Validate,
	subcommands: []^Cli_Command,
	parent:      ^Cli_Command,
}

Cli_Invocation :: struct {
	command: ^Cli_Command,
	path:    []string,
	flags:   map[string]Cli_Flag_Value,
	args:    []string,
	help:    bool,
}

Cli_Parse_Error_Kind :: enum {
	None,
	Unknown_Command,
	Missing_Subcommand,
	Unknown_Flag,
	Missing_Flag_Value,
	Invalid_Flag_Value,
	Duplicate_Flag,
	Missing_Required_Flag,
	Bad_Arg_Count,
	Failed_Validation,
}

Cli_Parse_Error :: struct {
	kind:    Cli_Parse_Error_Kind,
	token:   string,
	command: ^Cli_Command,
	detail:  string,
}

cli_find_subcommand :: proc(cmd: ^Cli_Command, name: string) -> ^Cli_Command {
	for sub in cmd.subcommands {
		if sub.use == name {
			return sub
		}
	}
	return nil
}

cli_find_flag :: proc(cmd: ^Cli_Command, name: string) -> ^Cli_Flag {
	for &f in cmd.flags {
		if f.name == name {
			return &f
		}
	}
	return nil
}

cli_find_shorthand :: proc(cmd: ^Cli_Command, r: rune) -> ^Cli_Flag {
	if r == 0 {
		return nil
	}
	for &f in cmd.flags {
		if f.shorthand == r {
			return &f
		}
	}
	return nil
}

cli_flag_bool :: proc(inv: ^Cli_Invocation, name: string) -> bool {
	if v, ok := inv.flags[name]; ok {
		if b, is := v.(bool); is {
			return b
		}
	}
	if f := cli_find_flag(inv.command, name); f != nil {
		if b, is := f.default.(bool); is {
			return b
		}
	}
	return false
}

cli_flag_string :: proc(inv: ^Cli_Invocation, name: string) -> string {
	if v, ok := inv.flags[name]; ok {
		if s, is := v.(string); is {
			return s
		}
	}
	if f := cli_find_flag(inv.command, name); f != nil {
		if s, is := f.default.(string); is {
			return s
		}
	}
	return ""
}

cli_flag_int :: proc(inv: ^Cli_Invocation, name: string) -> int {
	if v, ok := inv.flags[name]; ok {
		if i, is := v.(int); is {
			return i
		}
	}
	if f := cli_find_flag(inv.command, name); f != nil {
		if i, is := f.default.(int); is {
			return i
		}
	}
	return 0
}

cli_marshal_int_flag :: proc(args: ^[dynamic]string, inv: ^Cli_Invocation, name: string) {
	if _, passed := inv.flags[name]; passed {
		append(args, fmt.tprintf("--%s", name))
		append(args, fmt.tprintf("%d", cli_flag_int(inv, name)))
	}
}

cli_marshal_string_flag :: proc(args: ^[dynamic]string, inv: ^Cli_Invocation, name: string) {
	if _, passed := inv.flags[name]; passed {
		append(args, fmt.tprintf("--%s", name))
		append(args, cli_flag_string(inv, name))
	}
}

cli_command_path_string :: proc(cmd: ^Cli_Command, allocator := context.allocator) -> string {
	tokens := make([dynamic]string, 0, 4, context.temp_allocator)
	for c := cmd; c != nil; c = c.parent {
		append(&tokens, c.use)
	}
	slice.reverse(tokens[:])
	return strings.join(tokens[:], " ", allocator)
}

cli_finalize :: proc(cmd: ^Cli_Command) -> (ok: bool, message: string) {
	if cmd.run == nil && len(cmd.subcommands) == 0 {
		return false, fmt_command_error(cmd, "is neither runnable nor a parent (no run, no subcommands)")
	}
	seen_sub := make(map[string]bool, context.temp_allocator)
	for sub in cmd.subcommands {
		if seen_sub[sub.use] {
			return false, fmt_command_error(cmd, "declares duplicate subcommand: %s", sub.use)
		}
		seen_sub[sub.use] = true
		sub.parent = cmd
		if child_ok, child_msg := cli_finalize(sub); !child_ok {
			return false, child_msg
		}
	}
	seen_flag := make(map[string]bool, context.temp_allocator)
	seen_short := make(map[rune]bool, context.temp_allocator)
	for f in cmd.flags {
		if f.name == "help" || f.shorthand == 'h' {
			return false, fmt_command_error(cmd, "flag %s collides with the reserved --help/-h", f.name)
		}
		if seen_flag[f.name] {
			return false, fmt_command_error(cmd, "declares duplicate flag: --%s", f.name)
		}
		seen_flag[f.name] = true
		if f.shorthand != 0 {
			if seen_short[f.shorthand] {
				return false, fmt_command_error(cmd, "declares duplicate shorthand: -%v", f.shorthand)
			}
			seen_short[f.shorthand] = true
		}
	}
	return true, ""
}

fmt_command_error :: proc(cmd: ^Cli_Command, format: string, args: ..any) -> string {
	detail := fmt.aprintf(format, ..args, allocator = context.temp_allocator)
	return strings.concatenate({"command \"", cli_command_path_string(cmd, context.temp_allocator), "\" ", detail}, context.temp_allocator)
}

cli_nonempty :: proc(value: string) -> bool {
	return value != ""
}

cli_new_command :: proc(spec: Cli_Command, allocator := context.allocator) -> ^Cli_Command {
	cmd := new(Cli_Command, allocator)
	cmd^ = spec
	return cmd
}
