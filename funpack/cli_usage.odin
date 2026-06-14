// The CLI framework's help renderer: a deterministic, Cobra-shaped usage block
// for any command in the tree. It is a pure function of the linked command tree
// (no host state, no clock) and iterates only over declared slices — never a
// map — so two renders of the same tree are byte-identical, the §29 determinism
// floor the rest of funpack's renderers hold. The layout mirrors Cobra's:
//
//   <long or short description>
//
//   Usage:
//     funpack warden [command]
//     funpack warden find [flags] [args]
//
//   Available Commands:
//     find   Look up an existing declaration before writing one
//     …
//
//   Flags:
//     -r, --release   Ban typed holes (the shippable build)
//     -h, --help      help for warden
//
//   Use "funpack warden [command] --help" for more information about a command.
//
// Sections present themselves by shape: a parent shows Usage `[command]` and an
// Available Commands list; a runnable command shows a `[flags]` usage line (plus
// `[args]` when it accepts positionals); every command shows a Flags block with
// the synthetic `-h, --help`.
package funpack

import "core:fmt"
import "core:strings"

// cli_usage renders cmd's help block. Deterministic over the tree; allocated in
// `allocator`.
cli_usage :: proc(cmd: ^Cli_Command, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	path := cli_command_path_string(cmd, context.temp_allocator)

	if desc := cmd.long if cmd.long != "" else cmd.short; desc != "" {
		fmt.sbprintln(&b, desc)
		strings.write_byte(&b, '\n')
	}

	fmt.sbprintln(&b, "Usage:")
	if len(cmd.subcommands) > 0 {
		fmt.sbprintfln(&b, "  %s [command]", path)
	}
	if cmd.run != nil {
		if cmd.args.kind != .None {
			fmt.sbprintfln(&b, "  %s [flags] [args]", path)
		} else {
			fmt.sbprintfln(&b, "  %s [flags]", path)
		}
	}

	if len(cmd.subcommands) > 0 {
		strings.write_byte(&b, '\n')
		fmt.sbprintln(&b, "Available Commands:")
		width := 0
		for sub in cmd.subcommands {
			width = max(width, len(sub.use))
		}
		for sub in cmd.subcommands {
			strings.write_string(&b, "  ")
			cli_write_padded(&b, sub.use, width)
			strings.write_string(&b, "  ")
			strings.write_string(&b, sub.short)
			strings.write_byte(&b, '\n')
		}
	}

	cli_write_flags_section(&b, cmd)

	if len(cmd.subcommands) > 0 {
		strings.write_byte(&b, '\n')
		fmt.sbprintfln(&b, "Use \"%s [command] --help\" for more information about a command.", path)
	}
	return strings.to_string(b)
}

// cli_write_flags_section writes the Flags block: each declared flag's left
// column (shorthand + long name + type hint) padded to a shared width, then its
// usage, then the synthetic `-h, --help` line. The column width spans the local
// flags AND the help line so the whole block aligns.
cli_write_flags_section :: proc(b: ^strings.Builder, cmd: ^Cli_Command) {
	help_left :: "-h, --help"
	lefts := make([dynamic]string, 0, len(cmd.flags) + 1, context.temp_allocator)
	for f in cmd.flags {
		append(&lefts, cli_flag_left(f, context.temp_allocator))
	}
	width := len(help_left)
	for l in lefts {
		width = max(width, len(l))
	}

	strings.write_byte(b, '\n')
	fmt.sbprintln(b, "Flags:")
	for f, idx in cmd.flags {
		strings.write_string(b, "  ")
		cli_write_padded(b, lefts[idx], width)
		strings.write_string(b, "  ")
		strings.write_string(b, f.usage)
		strings.write_byte(b, '\n')
	}
	strings.write_string(b, "  ")
	cli_write_padded(b, help_left, width)
	strings.write_string(b, "  ")
	fmt.sbprintfln(b, "help for %s", cmd.use)
}

// cli_flag_left renders a flag's left column: `-x, --name` when it has a
// shorthand, `    --name` (aligned under the shorthand column) when it does not,
// with a ` string`/` int` type hint for value flags so the help reads like
// Cobra's. The shorthand is written as a rune (ASCII for every funpack flag), so
// the byte length equals the display width the pad relies on.
cli_flag_left :: proc(f: Cli_Flag, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	if f.shorthand != 0 {
		strings.write_byte(&b, '-')
		strings.write_rune(&b, f.shorthand)
		strings.write_string(&b, ", --")
	} else {
		strings.write_string(&b, "    --")
	}
	strings.write_string(&b, f.name)
	switch f.kind {
	case .String:
		strings.write_string(&b, " string")
	case .Int:
		strings.write_string(&b, " int")
	case .Bool:
	}
	return strings.to_string(b)
}

// cli_write_padded writes s followed by enough spaces to reach `width` columns,
// the manual left-justify the alignment uses (the codebase pads by hand rather
// than relying on a fmt width verb).
cli_write_padded :: proc(b: ^strings.Builder, s: string, width: int) {
	strings.write_string(b, s)
	for _ in len(s) ..< width {
		strings.write_byte(b, ' ')
	}
}
