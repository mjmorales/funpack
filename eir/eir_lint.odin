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
import "core:fmt"

// Lint is one registry entry: the metadata build_lint_subtree turns into a
// cli.Cli_Command leaf. name is the subcommand token (`eir <name>`), short/long
// the help text, args the positional-arity spec, and run the handler. The
// registry — not the host or the binary — is the single source of which lints
// exist, so `eir --help` lists exactly the registered set in declaration order.
Lint :: struct {
	name:  string,
	short: string,
	long:  string,
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
		long = "Walk the Odin/funpack source tree from the optional [root] (default cwd) and report duplicated AST subtrees — Type-1 exact and Type-2 renamed clones — following the dup_class doctrine.",
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
// sources, run the clone engine over the parsed trees with the default options, and
// print a one-line summary. It returns 0 even when clones are found — the {0 clean,
// 1 clones, 2 usage} verdict contract and the rich human/JSON report are the report
// surface's concern, kept OUT of the engine wiring; here a non-resolvable root is the
// only non-zero path (exit 2, a bad path argument). A parse failure is surfaced in
// the summary, never an abort: the scan reports clones over what it could read.
run_dup_lint :: proc(inv: ^cli.Cli_Invocation) -> int {
	root := "."
	if len(inv.args) > 0 {
		root = inv.args[0]
	}

	l: Loader
	loader_init(&l)
	defer loader_destroy(&l)

	result, ok := load_dir(&l, root, nil)
	if !ok {
		fmt.eprintfln("eir dup: cannot scan %q", root)
		return 2
	}

	classes := find_clones(result, dup_default_options())
	fmt.printfln(
		"eir dup: %d clone class(es) across %d file(s) (%d parse failure(s))",
		len(classes),
		len(result.files),
		result.parse_failures,
	)
	return 0
}
