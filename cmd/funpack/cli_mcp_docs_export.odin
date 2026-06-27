package main

import "../../cli"
import "core:fmt"
import "core:slice"

build_mcp_docs_export_command :: proc(allocator := context.allocator) -> ^cli.Cli_Command {
	return cli.cli_new_command(
		cli.Cli_Command {
			use = "docs-export",
			short = "Materialize the embedded docs corpus to a traversable on-disk tree",
			long = "Materialize this binary's embedded docs corpus to an on-disk Markdown tree an agent can Read/Grep/follow-anchor, alongside the in-process docs_search/docs_get tools. The bytes come from the binary's #load'd corpus, so the tree is coherent with the compiler and version-keyed by the manifest funpack version. With no flag it writes the managed-home tree (~/.funpack/docs/<version>); --dir <path> writes the tree directly into <path> instead. The MCP server also writes this tree once at startup; this subcommand is the explicit handle (pre-warm, relocate, or re-emit). Idempotent: a populated, version-matching tree is a no-op. Writes a runtime artifact under the managed home — it never touches the working tree (unlike gen-corpus).",
			args = cli.cli_no_args(),
			run = cli_run_mcp_docs_export,
			flags = slice.clone(
				[]cli.Cli_Flag {
					{
						name = "dir",
						kind = .String,
						usage = "explicit root to export the tree into (default: ~/.funpack/docs/<version>)",
					},
				},
				allocator,
			),
		},
		allocator,
	)
}

cli_run_mcp_docs_export :: proc(inv: ^cli.Cli_Invocation) -> int {
	// Stays on the heap (context.allocator): the ~520K materialization overruns the default scratch temp arena.
	if _, passed := inv.flags["dir"]; passed {
		dir := cli.cli_flag_string(inv, "dir")
		wrote, ok := docs_export_into(dir, context.allocator)
		if !ok {
			fmt.eprintfln("mcp docs-export: could not materialize the docs tree under %s (corpus parse or write failure)", dir)
			return 1
		}
		if wrote {
			fmt.eprintfln("mcp docs-export: docs tree materialized at %s", dir)
		} else {
			fmt.eprintfln("mcp docs-export: %s already current (no-op)", dir)
		}
		return 0
	}

	root, ok := docs_export_default(context.allocator)
	if !ok {
		fmt.eprintln("mcp docs-export: could not materialize the docs tree (no writable ~/.funpack home) — set HOME or pass --dir <path>")
		return 1
	}
	fmt.eprintfln("mcp docs-export: docs tree materialized at %s", root)
	return 0
}
