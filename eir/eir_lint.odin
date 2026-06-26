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

// run_dup_lint handles `eir dup`. With no clone engine wired, it emits a status
// line and exits 0 — deliberately NOT a verdict: an exit 1 would read as "clones
// found" and an exit 2 as a usage error, either of which a CI gate could act on.
// The signature and registry entry are the durable contract; the engine fills
// this body.
run_dup_lint :: proc(_: ^cli.Cli_Invocation) -> int {
	fmt.println("eir dup: the duplication lint is not yet implemented")
	return 0
}
