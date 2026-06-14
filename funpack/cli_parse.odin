// The CLI framework's resolver and dispatch. cli_parse is the PURE half — it
// walks a command tree against an argument vector and returns either a fully
// resolved Cli_Invocation or a closed Cli_Parse_Error, reading no host state and
// touching no disk. cli_dispatch is the thin EFFECTFUL half — it runs the parse,
// prints
// usage on an error (exit 2) or on `--help` (exit 0), and otherwise calls the
// resolved command's handler and returns ITS exit code. The split keeps the
// engine boundary (design principle §1): the framework resolves arguments; a
// verb owns its {0, 1, 2} exit contract.
//
// The grammar cli_parse accepts: leading non-flag tokens descend the command
// tree; then, for the resolved command, `--name`, `--name=value`, `--name
// value`, `-x`, `-x=value`, `-xvalue`, bare `--` (end-of-flags), and positional
// arguments, with `--help`/`-h` recognized at any command level. Bool flags are
// presence-valued and never consume the following token (`--release true`
// leaves "true" a positional — the Cobra rule).
package funpack

import "core:fmt"
import "core:strconv"
import "core:strings"

// cli_parse resolves argv against the command tree rooted at root. It descends
// subcommands on leading non-flag tokens, binds the resolved command's flags,
// collects positionals, then adjudicates — in order — a missing subcommand on a
// pure parent, unset required flags, positional arity, and the command's
// optional cross-cutting validate hook. The first failure returns a
// Cli_Parse_Error with kind != .None and the offending command for usage
// rendering; success returns the invocation and a zero (.None) error. Pure: a
// function of (root, argv) alone, allocating its result collections in
// `allocator`.
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

	// Descend the tree while the next token is a plain word that names a child.
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

	// Bind flags and collect positionals for the resolved command.
	flags := make(map[string]Cli_Flag_Value, allocator = allocator)
	args := make([dynamic]string, 0, len(argv), allocator)
	positional_only := false
	for i < len(argv) {
		token := argv[i]
		if !positional_only {
			if token == "--" {
				// POSIX end-of-flags: every later token is positional.
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
				// A value may be glued to the shorthand: -xVALUE or -x=VALUE.
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

	// A pure parent reached without a subcommand has nothing to run.
	if cmd.run == nil && len(cmd.subcommands) > 0 {
		return {}, Cli_Parse_Error{kind = .Missing_Subcommand, command = cmd}
	}
	// Required flags must be bound.
	for f in cmd.flags {
		if !f.required {
			continue
		}
		if _, ok := flags[f.name]; !ok {
			return {}, Cli_Parse_Error{kind = .Missing_Required_Flag, token = f.name, command = cmd}
		}
	}
	// Positional arity.
	if !cli_args_check(cmd.args, len(args)) {
		return {}, Cli_Parse_Error {
			kind = .Bad_Arg_Count,
			command = cmd,
			detail = cli_args_expectation(cmd.args, allocator),
		}
	}
	inv := Cli_Invocation{command = cmd, path = path[:], flags = flags, args = args[:], help = false}
	// The command's optional cross-cutting predicate runs last, over the fully
	// bound invocation (e.g. warden find's "at least one non-empty filter").
	if cmd.validate != nil && !cmd.validate(&inv) {
		return {}, Cli_Parse_Error{kind = .Failed_Validation, command = cmd}
	}
	return inv, {}
}

// cli_bind_value binds one flag's value into the flags map and reports how many
// argv tokens it consumed (1 for an inline/bool form, 2 when the value is the
// following token). A flag already present is a Duplicate_Flag; a value flag
// with no available value is a Missing_Flag_Value; a value rejected by the
// flag's validate predicate, an unparsable bool, or an unparsable int is an
// Invalid_Flag_Value. Errors carry the flag's long name as their token (the
// caller stamps the command).
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
	if f.kind == .Bool {
		// A bool is presence-valued; an explicit `=true`/`=false` overrides.
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
	// String / Int consume a value: the inline form, else the next token.
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
	switch f.kind {
	case .String:
		flags[f.name] = value
	case .Int:
		n, ok := strconv.parse_int(value)
		if !ok {
			return 0, Cli_Parse_Error{kind = .Invalid_Flag_Value, token = f.name}
		}
		flags[f.name] = n
	case .Bool:
	// Handled above; unreachable here.
	}
	return consumed, {}
}

// cli_dispatch is the effectful entry point main calls: parse, then on a usage
// error print the error and the command's usage to stderr and return 2 (the
// usage tier every front-door verb shares); on `--help` print the usage to
// stdout and return 0; otherwise call the resolved command's handler and return
// its exit code. The exit number is the verb's — cli_dispatch only relays it.
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
	if inv.command.run == nil {
		// Defensive: cli_parse rejects a leaf-less parent as Missing_Subcommand,
		// so this fires only on a tree that skipped cli_finalize's checks.
		fmt.eprint(cli_usage(inv.command, context.temp_allocator))
		return 2
	}
	return inv.command.run(&inv)
}

// cli_render_parse_error renders a parse failure: a `Error: <message>` line (when
// the kind carries one) followed by the offending command's usage block — the
// Cobra shape, so an operator sees both what went wrong and how to invoke the
// command. Advisory text; the machine contract is the exit code cli_dispatch
// returns. Deterministic over the error.
cli_render_parse_error :: proc(err: Cli_Parse_Error, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	if msg := cli_parse_error_message(err, context.temp_allocator); msg != "" {
		fmt.sbprintfln(&b, "Error: %s", msg)
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, cli_usage(err.command, context.temp_allocator))
	return strings.to_string(b)
}

// cli_parse_error_message renders the one-line advisory for a parse-error kind.
// Missing_Subcommand has no message — its usage block alone is the cue, matching
// the bare `funpack` / `funpack warden` no-verb case.
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

// cli_is_flag reports whether a token is a flag attempt — a leading '-' that is
// not the bare "-" (which, by convention, is a positional, e.g. stdin). Used to
// stop the command-tree descent at the first flag.
cli_is_flag :: proc(token: string) -> bool {
	return len(token) >= 1 && token[0] == '-' && token != "-"
}

// cli_is_long reports a long flag: a `--name` token (with a name after the two
// dashes, so the bare "--" terminator is excluded).
cli_is_long :: proc(token: string) -> bool {
	return strings.has_prefix(token, "--") && len(token) > 2
}

// cli_is_short reports a short flag: a `-x…` token whose first post-dash byte is
// not another dash.
cli_is_short :: proc(token: string) -> bool {
	return len(token) >= 2 && token[0] == '-' && token[1] != '-'
}

// cli_split_eq splits a `name=value` flag body on its first '=' into the name,
// the value, and whether an '=' was present (`--kind=Fn` ⇒ "kind", "Fn", true;
// `--release` ⇒ "release", "", false).
cli_split_eq :: proc(s: string) -> (name: string, value: string, has: bool) {
	if idx := strings.index_byte(s, '='); idx >= 0 {
		return s[:idx], s[idx + 1:], true
	}
	return s, "", false
}

// cli_parse_bool parses a bool flag's explicit value — exactly "true" or
// "false", nothing fuzzier, so `--release=maybe` is a usage error rather than a
// silently-coerced value.
cli_parse_bool :: proc(s: string) -> (value: bool, ok: bool) {
	switch s {
	case "true":
		return true, true
	case "false":
		return false, true
	}
	return false, false
}
