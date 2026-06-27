package cli

import "core:fmt"
import "core:strconv"
import "core:strings"

cli_parse :: proc(
	root: ^Cli_Command,
	argv: []string,
	allocator := context.allocator,
) -> (
	Cli_Invocation,
	Cli_Parse_Error,
) {
	cmd := root
	path := make([dynamic]string, 0, 4, allocator)
	append(&path, cmd.use)

	i := 0
	for len(cmd.subcommands) > 0 && i < len(argv) && !cli_is_flag(argv[i]) {
		sub := cli_find_subcommand(cmd, argv[i])
		if sub == nil {
			return {}, Cli_Parse_Error{kind = .Unknown_Command, token = argv[i], command = cmd}
		}
		cmd = sub
		append(&path, cmd.use)
		i += 1
	}

	flags := make(map[string]Cli_Flag_Value, allocator = allocator)
	args := make([dynamic]string, 0, len(argv), allocator)
	positional_only := false
	for i < len(argv) {
		token := argv[i]
		if !positional_only {
			if token == "--" {
				positional_only = true
				i += 1
				continue
			}
			if token == "--help" || token == "-h" {
				inv := Cli_Invocation {
					command = cmd,
					path    = path[:],
					flags   = flags,
					args    = args[:],
					help    = true,
				}
				return inv, {}
			}
			if cli_is_long(token) {
				name, inline_val, has_inline := cli_split_eq(token[2:])
				f := cli_find_flag(cmd, name)
				if f == nil {
					return {}, Cli_Parse_Error{kind = .Unknown_Flag, token = token, command = cmd}
				}
				consumed, perr := cli_bind_value(f, &flags, has_inline, inline_val, argv, i)
				if perr.kind != .None {
					perr.command = cmd
					return {}, perr
				}
				i += consumed
				continue
			}
			if cli_is_short(token) {
				f := cli_find_shorthand(cmd, rune(token[1]))
				if f == nil {
					return {}, Cli_Parse_Error{kind = .Unknown_Flag, token = token, command = cmd}
				}
				rest := token[2:]
				has_inline := len(rest) > 0
				inline_val := rest
				if has_inline && rest[0] == '=' {
					inline_val = rest[1:]
				}
				consumed, perr := cli_bind_value(f, &flags, has_inline, inline_val, argv, i)
				if perr.kind != .None {
					perr.command = cmd
					return {}, perr
				}
				i += consumed
				continue
			}
		}
		append(&args, token)
		i += 1
	}

	if cmd.run == nil && len(cmd.subcommands) > 0 {
		return {}, Cli_Parse_Error{kind = .Missing_Subcommand, command = cmd}
	}
	for f in cmd.flags {
		if !f.required {
			continue
		}
		if _, ok := flags[f.name]; !ok {
			return {}, Cli_Parse_Error{kind = .Missing_Required_Flag, token = f.name, command = cmd}
		}
	}
	if !cli_args_check(cmd.args, len(args)) {
		return {}, Cli_Parse_Error {
			kind = .Bad_Arg_Count,
			command = cmd,
			detail = cli_args_expectation(cmd.args, allocator),
		}
	}
	inv := Cli_Invocation{command = cmd, path = path[:], flags = flags, args = args[:], help = false}
	if cmd.validate != nil && !cmd.validate(&inv) {
		return {}, Cli_Parse_Error{kind = .Failed_Validation, command = cmd}
	}
	return inv, {}
}

cli_bind_value :: proc(
	f: ^Cli_Flag,
	flags: ^map[string]Cli_Flag_Value,
	has_inline: bool,
	inline_val: string,
	argv: []string,
	idx: int,
) -> (
	consumed: int,
	err: Cli_Parse_Error,
) {
	if _, dup := flags[f.name]; dup {
		return 0, Cli_Parse_Error{kind = .Duplicate_Flag, token = f.name}
	}
	// Bool is presence-valued and never consumes the next token (the Cobra rule).
	if f.kind == .Bool {
		if has_inline {
			b, ok := cli_parse_bool(inline_val)
			if !ok {
				return 0, Cli_Parse_Error{kind = .Invalid_Flag_Value, token = f.name}
			}
			flags[f.name] = b
		} else {
			flags[f.name] = true
		}
		return 1, {}
	}
	value: string
	if has_inline {
		value = inline_val
		consumed = 1
	} else {
		if idx + 1 >= len(argv) {
			return 0, Cli_Parse_Error{kind = .Missing_Flag_Value, token = f.name}
		}
		value = argv[idx + 1]
		consumed = 2
	}
	if f.validate != nil && !f.validate(value) {
		return 0, Cli_Parse_Error{kind = .Invalid_Flag_Value, token = f.name}
	}
	#partial switch f.kind {
	case .String:
		flags[f.name] = value
	case .Int:
		n, ok := strconv.parse_int(value)
		if !ok {
			return 0, Cli_Parse_Error{kind = .Invalid_Flag_Value, token = f.name}
		}
		flags[f.name] = n
	}
	return consumed, {}
}

cli_dispatch :: proc(root: ^Cli_Command, argv: []string) -> int {
	inv, err := cli_parse(root, argv, context.temp_allocator)
	if err.kind != .None {
		fmt.eprint(cli_render_parse_error(err, context.temp_allocator))
		return 2
	}
	if inv.help {
		fmt.print(cli_usage(inv.command, context.temp_allocator))
		return 0
	}
	// Unreachable once cli_finalize ran; guards a tree that skipped its checks.
	if inv.command.run == nil {
		fmt.eprint(cli_usage(inv.command, context.temp_allocator))
		return 2
	}
	return inv.command.run(&inv)
}

cli_render_parse_error :: proc(err: Cli_Parse_Error, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	if msg := cli_parse_error_message(err, context.temp_allocator); msg != "" {
		fmt.sbprintfln(&b, "Error: %s", msg)
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, cli_usage(err.command, context.temp_allocator))
	return strings.to_string(b)
}

cli_parse_error_message :: proc(err: Cli_Parse_Error, allocator := context.allocator) -> string {
	switch err.kind {
	case .None:
		return ""
	case .Unknown_Command:
		return fmt.aprintf("unknown command \"%s\"", err.token, allocator = allocator)
	case .Missing_Subcommand:
		return ""
	case .Unknown_Flag:
		return fmt.aprintf("unknown flag: %s", err.token, allocator = allocator)
	case .Missing_Flag_Value:
		return fmt.aprintf("flag --%s needs a value", err.token, allocator = allocator)
	case .Invalid_Flag_Value:
		return fmt.aprintf("invalid value for flag --%s", err.token, allocator = allocator)
	case .Duplicate_Flag:
		return fmt.aprintf("flag --%s set more than once", err.token, allocator = allocator)
	case .Missing_Required_Flag:
		return fmt.aprintf("required flag --%s not set", err.token, allocator = allocator)
	case .Bad_Arg_Count:
		return fmt.aprintf("accepts %s", err.detail, allocator = allocator)
	case .Failed_Validation:
		return "invalid arguments"
	}
	return ""
}

cli_is_flag :: proc(token: string) -> bool {
	return len(token) >= 1 && token[0] == '-' && token != "-"
}

cli_is_long :: proc(token: string) -> bool {
	return strings.has_prefix(token, "--") && len(token) > 2
}

cli_is_short :: proc(token: string) -> bool {
	return len(token) >= 2 && token[0] == '-' && token[1] != '-'
}

cli_split_eq :: proc(s: string) -> (name: string, value: string, has: bool) {
	if idx := strings.index_byte(s, '='); idx >= 0 {
		return s[:idx], s[idx + 1:], true
	}
	return s, "", false
}

cli_parse_bool :: proc(s: string) -> (value: bool, ok: bool) {
	switch s {
	case "true":
		return true, true
	case "false":
		return false, true
	}
	return false, false
}
