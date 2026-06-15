// The funpack CLI framework — a Cobra-shaped command/flag library that the
// front-door verbs (version, test, build, check, fmt, warden …) declare
// themselves into: ONE declarative command tree resolves every verb, flag, and
// subcommand.
//
// The library holds the same engine boundary the rest of funpack does (design
// principle §1): cli_parse is PURE — argument text in, a resolved Cli_Invocation
// (or a Cli_Parse_Error) out, no host state, no IO, no process exit — and the
// effectful half (printing usage, calling a verb's handler) lives in
// cli_dispatch (cli_parse.odin). That split keeps parse pure and execution
// separate (the run_X_verb effect and the X_verb_exit(root, …) testable core
// stay verb-owned), so each verb keeps owning its documented {0, 1, 2} exit
// contract (§29 §3): the framework resolves arguments; it NEVER decides an exit
// code. Every
// taxonomy here (flag kind, args kind, parse-error kind) is a closed enum under
// the usual discipline (§4) — a new shape is a new member, never a stringly
// dispatched extra.
//
// This file is the data model: the Cli_Command tree, its Cli_Flag set, the
// resolved Cli_Invocation, and the closed Cli_Parse_Error vocabulary, plus the
// pure lookups and typed flag getters a handler reads its bound values through.
// cli_args.odin owns positional arity, cli_parse.odin the pure resolver and the
// effectful dispatch, cli_usage.odin the deterministic help render, and
// cli_funpack.odin the concrete funpack command tree.
package cli

import "core:fmt"
import "core:strings"

// Cli_Flag_Kind is the closed value taxonomy a flag binds to. Bool flags are
// presence-valued (`--release` ⇒ true, no token consumed — the Cobra rule);
// String and Int flags consume a value (`--kind Fn`, `--kind=Fn`). A new value
// type is a new member here plus its arm in cli_bind_value (cli_parse.odin).
Cli_Flag_Kind :: enum {
	Bool,
	String,
	Int,
}

// Cli_Flag_Value is the bound value carried in an invocation's flag map. The
// nil union (no active variant) marks "absent" — a getter falls back to the
// flag's declared default, then to the type zero. The variant set mirrors
// Cli_Flag_Kind one-for-one.
Cli_Flag_Value :: union {
	bool,
	string,
	int,
}

// Cli_Flag_Validate is an OPTIONAL pure predicate a value flag runs at PARSE
// time, before the invocation is ever handed to a verb. It is the seam that
// keeps the framework domain-agnostic while still adjudicating domain
// constraints at parse: `funpack warden find --kind` validates its value
// against the closed Index_Decl_Kind member names through this hook
// (cli_validate_index_decl_kind, cli_funpack.odin), so an unknown kind is a
// usage error before any index read. A nil predicate accepts any well-typed
// value.
Cli_Flag_Validate :: #type proc(value: string) -> bool

// Cli_Flag declares one flag on a command. name is the long spelling without
// the leading `--`; shorthand is its single-character alias (0 = none); kind
// selects how the value is bound; usage is the one-line help; default supplies
// the getter's fallback when the flag is absent (nil union ⇒ type zero);
// required fails the parse when the flag is unset; validate is the optional
// parse-time value predicate above.
Cli_Flag :: struct {
	name:      string,
	shorthand: rune,
	kind:      Cli_Flag_Kind,
	usage:     string,
	default:   Cli_Flag_Value,
	required:  bool,
	validate:  Cli_Flag_Validate,
}

// Cli_Run is a leaf command's handler: it reads the resolved invocation and
// returns the verb's exit code. The framework calls it ONLY from cli_dispatch,
// never from cli_parse — so a handler runs against a fully validated invocation
// and the {0, 1, 2} exit decision stays the verb's, never the framework's. A
// nil run marks a pure parent (a group whose only job is to route to a
// subcommand); invoking a parent with no subcommand is a usage error.
Cli_Run :: #type proc(inv: ^Cli_Invocation) -> int

// Cli_Validate is a command's OPTIONAL post-bind cross-cutting predicate, run
// at the END of a successful parse over the fully bound invocation. It is the
// seam for constraints no single flag or arity rule expresses — e.g. `warden
// find`'s "at least one non-empty filter, and never an empty name-query" gate.
// Pure: it reads the invocation and returns ok; false is a usage error.
Cli_Validate :: #type proc(inv: ^Cli_Invocation) -> bool

// Cli_Command is one node of the command tree. use is the single token that
// selects this command from its parent (the root's use is the program name,
// `funpack`, and is never matched against an argument — the root is
// pre-selected). short/long are the help descriptions (long falls back to
// short). flags are this command's local flags; args is its positional arity
// spec (the zero value is Arbitrary). run is the leaf handler (nil = a pure
// parent). validate is the optional post-bind predicate. subcommands are the
// child nodes. parent is wired by cli_finalize (nil at the root) so usage and
// error rendering can reconstruct the full command path without threading it
// through every call.
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

// Cli_Invocation is the resolved result of a successful parse: the leaf command
// that matched, the full command path from the root down to it (for display),
// the bound flag values keyed by long name, the positional arguments after the
// command path, and whether `--help`/`-h` was requested. A handler reads flags
// through the typed getters below and positionals through args directly.
Cli_Invocation :: struct {
	command: ^Cli_Command,
	path:    []string,
	flags:   map[string]Cli_Flag_Value,
	args:    []string,
	help:    bool,
}

// Cli_Parse_Error_Kind is the closed failure vocabulary cli_parse returns. None
// is the success sentinel (err.kind == .None ⇔ the invocation is valid). Every
// other member is a usage failure the caller maps to funpack's exit 2 — the
// framework names the failure shape; the verb owns the exit code.
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

// Cli_Parse_Error carries a parse failure: its closed kind, the offending token
// (a command/flag name, "" when not applicable), the command the failure was
// adjudicated against (so the renderer can print that command's usage), and an
// optional human detail (e.g. the expected arity for Bad_Arg_Count). It is a
// plain value — cli_parse returns it by value with kind == .None on success.
Cli_Parse_Error :: struct {
	kind:    Cli_Parse_Error_Kind,
	token:   string,
	command: ^Cli_Command,
	detail:  string,
}

// cli_find_subcommand returns the child whose use token equals name, or nil.
// A linear scan in declared order — the subcommand set is tiny and the scan
// keeps resolution a deterministic function of declaration order.
cli_find_subcommand :: proc(cmd: ^Cli_Command, name: string) -> ^Cli_Command {
	for sub in cmd.subcommands {
		if sub.use == name {
			return sub
		}
	}
	return nil
}

// cli_find_flag returns a pointer to the local flag whose long name equals
// name, or nil. The pointer aliases the command's flag slice (which lives as
// long as the command), so binding and getters read the spec in place.
cli_find_flag :: proc(cmd: ^Cli_Command, name: string) -> ^Cli_Flag {
	for &f in cmd.flags {
		if f.name == name {
			return &f
		}
	}
	return nil
}

// cli_find_shorthand returns the local flag whose shorthand equals r (a nonzero
// rune), or nil. Shorthand 0 means "no shorthand" and never matches.
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

// cli_flag_bool reads a bound bool flag: the bound value if present, else the
// flag's declared bool default, else false. The three-tier fallback is why a
// verb can map `--release` to a mode with a single boolean read and trust an
// absent flag to be the false case.
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

// cli_flag_string reads a bound string flag: the bound value if present, else
// the declared string default, else "". A verb treats "" as "not provided" (the
// warden find mappers do exactly this), so an unset optional string flag and an
// explicitly-empty one collapse to the same absent case.
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

// cli_flag_int reads a bound int flag: the bound value if present, else the
// declared int default, else 0.
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

// cli_command_path_string renders the space-joined command path from the root
// down to cmd (e.g. "funpack warden find"), walking parent pointers wired by
// cli_finalize. Used by the usage and error renderers; deterministic, a pure
// function of the linked tree.
cli_command_path_string :: proc(cmd: ^Cli_Command, allocator := context.allocator) -> string {
	tokens := make([dynamic]string, 0, 4, context.temp_allocator)
	for c := cmd; c != nil; c = c.parent {
		append(&tokens, c.use)
	}
	// Parents were appended leaf-first; reverse to root-first for display.
	slice_reverse_strings(tokens[:])
	return strings.join(tokens[:], " ", allocator)
}

// slice_reverse_strings reverses a string slice in place — the small helper
// cli_command_path_string needs because it collects the path leaf-first.
slice_reverse_strings :: proc(s: []string) {
	for i, j := 0, len(s) - 1; i < j; i, j = i + 1, j - 1 {
		s[i], s[j] = s[j], s[i]
	}
}

// cli_finalize wires the tree for use: it sets every node's parent pointer (so
// path reconstruction works) and validates the authored tree is well-formed —
// unique subcommand use tokens per node, unique flag names and shorthands per
// command, and every node either runs or routes (a leaf has a handler, a parent
// has subcommands). A malformed tree is a programmer error in the in-repo
// declaration, so finalize reports it as (ok = false, message) for a startup
// assertion and a unit test, never a runtime parse path. Returns ok = true and
// "" when the whole tree is well-formed.
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

// fmt_command_error formats a cli_finalize diagnostic, prefixing the offending
// command's path so a malformed-tree message names exactly which node is wrong.
fmt_command_error :: proc(cmd: ^Cli_Command, format: string, args: ..any) -> string {
	detail := fmt.aprintf(format, ..args, allocator = context.temp_allocator)
	return strings.concatenate({"command \"", cli_command_path_string(cmd, context.temp_allocator), "\" ", detail}, context.temp_allocator)
}

// cli_nonempty is a reusable Cli_Flag_Validate that rejects an empty value, so a
// `--gtag ""` (a tag identity names no registered tag) is a usage error rather
// than a silently-empty filter.
cli_nonempty :: proc(value: string) -> bool {
	return value != ""
}

// cli_new_command heap-copies a command spec into `allocator` and returns its
// stable address — the addressable node cli_finalize threads parent pointers
// through and subcommand slices reference. Lives in the framework package so
// every domain that authors a tree (the funpack compiler subtree, the entry
// package's runtime nodes) constructs nodes through one shared constructor.
cli_new_command :: proc(spec: Cli_Command, allocator := context.allocator) -> ^Cli_Command {
	cmd := new(Cli_Command, allocator)
	cmd^ = spec
	return cmd
}
