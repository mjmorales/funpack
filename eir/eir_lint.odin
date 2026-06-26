// The eir lint HOST — a registry of repo-local source lints composed over the
// domain-free cli framework. eir is the analog of cmd/funpack's compiler subtree:
// a data-driven set of verb nodes the entry binary (cmd/eir) grafts onto its
// root. Each lint is one Lint registry entry; build_lint_subtree turns the whole
// registry into cli.Cli_Command nodes, so adding a lint is a new entry in
// lint_registry and nothing else — never a hand-built command in the host or the
// binary.
//
// dup (the first lint) is an AST DRY/clone checker. Its clone engine is wired in
// a separate change; the registry shape is what survives that landing — only
// run_dup_lint's body changes, never its registration or signature.
package eir

import "../cli"
import vmem "core:mem/virtual"
import "core:fmt"
import "core:strings"

// Lint is one registry entry: the metadata build_lint_subtree turns into a
// cli.Cli_Command leaf. name is the subcommand token (`eir <name>`), short/long
// the help text, flags the lint's own local flags (each a cli.Cli_Flag — a lint
// declares its flag surface alongside its arity, so the registry stays the single
// source of a lint's whole CLI shape), args the positional-arity spec, and run the
// handler. The registry — not the host or the binary — is the single source of
// which lints exist, so `eir --help` lists exactly the registered set in
// declaration order.
Lint :: struct {
	name:  string,
	short: string,
	long:  string,
	flags: []cli.Cli_Flag,
	args:  cli.Cli_Args,
	run:   cli.Cli_Run,
}

// lint_registry is the closed set of lints eir hosts, in the order `eir --help`
// renders them. dup (the AST DRY checker) is the first; a second lint is one more
// entry here. Static data — string literals, an arity spec, and a package-level
// handler address — so it needs no allocation. The arity helpers (cli_range_args
// &c.) are contextless, so they build the spec here at file scope.
lint_registry := []Lint {
	{
		name = "dup",
		short = "Report Type-1/Type-2 AST clones in the source tree (DRY checker)",
		long = "Walk the Odin/funpack source tree from the optional [root] (default cwd) and report duplicated AST subtrees — Type-1 exact and Type-2 renamed clones — following the dup_class doctrine. Prints a ranked human table by default, or --json for a byte-stable clone-class array an agent can rank to the highest-leverage dedup target.",
		flags = []cli.Cli_Flag {
			// --exclude is a comma-separated glob list, not a repeatable flag: the cli
			// framework rejects a second occurrence of one flag as Duplicate_Flag, so a
			// multi-pattern exclude rides one string the lint splits on commas.
			{
				name = "exclude",
				kind = .String,
				usage = "Comma-separated glob list of paths to skip (e.g. 'cmd/funpack/mcp/corpus/,*.gen.odin')",
			},
			{
				name = "min-nodes",
				kind = .Int,
				usage = "Subtree node-count floor below which a clone class is dropped as noise",
				default = DEFAULT_MIN_NODES,
			},
			{
				name = "fold-literals",
				kind = .Bool,
				usage = "Collapse every literal to one token so constant-only differences collide",
			},
			{
				name = "json",
				kind = .Bool,
				usage = "Emit the ranked clone classes as byte-stable JSON instead of the human table",
			},
		},
		args = cli.cli_range_args(0, 1),
		run = run_dup_lint,
	},
}

// build_lint_subtree materializes the registry into cli.Cli_Command leaf nodes —
// one per Lint, allocated in `allocator` so each has the stable address
// cli_finalize threads parent pointers through. The entry binary uses the
// returned slice directly as the eir root's subcommands; the order mirrors
// lint_registry, keeping the help listing deterministic.
build_lint_subtree :: proc(allocator := context.allocator) -> []^cli.Cli_Command {
	nodes := make([dynamic]^cli.Cli_Command, 0, len(lint_registry), allocator)
	for lint in lint_registry {
		append(
			&nodes,
			cli.cli_new_command(
				cli.Cli_Command {
					use = lint.name,
					short = lint.short,
					long = lint.long,
					flags = lint.flags,
					args = lint.args,
					run = lint.run,
				},
				allocator,
			),
		)
	}
	return nodes[:]
}

// run_dup_lint handles `eir dup`: scan the optional [root] (default cwd) for Odin
// sources under the flag-driven options, run the clone engine over the parsed trees,
// and render the ranked report — the human table by default, the byte-stable JSON
// under --json. It returns 0 even when clones are found: the dup lint is a REPORT,
// not a CI gate, so its exit contract here is {0 informational, 2 usage} — a
// non-resolvable [root] is the only non-zero path (exit 2, a bad path argument), and
// a clone is never an exit 1 in this surface. Parse failures are surfaced as a stderr
// note, never an abort: the scan reports clones over what it could read.
//
// The whole scan — the loader's parse cache, every parsed tree and borrowed path
// string, the clone classes, and the rendered report — lives in one growing arena
// freed on return, so the load disposes in a single stroke (the loader's own
// destroy frees its cache index within that arena).
run_dup_lint :: proc(inv: ^cli.Cli_Invocation) -> int {
	root := "."
	if len(inv.args) > 0 {
		root = inv.args[0]
	}

	arena: vmem.Arena
	if arena_err := vmem.arena_init_growing(&arena); arena_err != .None {
		fmt.eprintln("eir dup: cannot initialize the scan arena")
		return 2
	}
	defer vmem.arena_destroy(&arena)
	scan := vmem.arena_allocator(&arena)

	excludes := parse_exclude_flag(cli.cli_flag_string(inv, "exclude"), scan)
	options := Dup_Options {
		min_nodes     = cli.cli_flag_int(inv, "min-nodes"),
		fold_literals = cli.cli_flag_bool(inv, "fold-literals"),
	}

	l: Loader
	loader_init(&l, scan)
	defer loader_destroy(&l)

	result, ok := load_dir(&l, root, excludes)
	if !ok {
		fmt.eprintfln("eir dup: cannot scan %q", root)
		return 2
	}

	classes := find_clones(result, options, scan)

	if result.parse_failures > 0 {
		fmt.eprintfln(
			"eir dup: %d file(s) failed to parse and were skipped",
			result.parse_failures,
		)
	}

	if cli.cli_flag_bool(inv, "json") {
		fmt.println(render_dup_json(classes, scan))
	} else {
		fmt.print(render_dup_human(classes, scan))
	}
	return 0
}

// parse_exclude_flag splits the comma-separated --exclude value into the glob list
// the loader prunes against, trimming surrounding whitespace and dropping empty
// segments so a trailing comma or a stray space never yields an empty glob (which
// would match nothing useful). An empty value yields nil — the "no excludes" case.
@(private = "file")
parse_exclude_flag :: proc(raw: string, allocator := context.allocator) -> []string {
	if raw == "" {
		return nil
	}
	out := make([dynamic]string, 0, 4, allocator)
	rest := raw
	for segment in strings.split_iterator(&rest, ",") {
		trimmed := strings.trim_space(segment)
		if trimmed != "" {
			append(&out, trimmed)
		}
	}
	return out[:]
}
