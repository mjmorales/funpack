// The `funpack mcp docs-export` subcommand — the explicit/standalone driver for the
// on-disk docs projection (mcp_docs_export.odin). It materializes the binary's
// compile-time-embedded docs corpus to a traversable Markdown tree the agent can
// Read/Grep/follow-anchor, the same tree the MCP server writes once at startup
// (mcp_materialize_docs_projection). This is the operator-facing handle for that
// materialization — useful to pre-warm the tree, to point it at a project-local or
// shared location with `--dir`, or to re-emit after a managed-binary update.
//
// IT IS A PROJECTION, NOT A SOURCE: the bytes come from THIS binary's #load'd corpus,
// so the tree is coherent with the compiler by construction and version-keyed by the
// manifest funpack version (the default path's leaf segment). UNLIKE `gen-corpus`
// (which rewrites committed repo source from the spec/.fun/skill trees and is dev-only),
// docs-export writes a runtime artifact under the managed home and never touches the
// working tree. Exit 0 on success, 1 on a resolve/write failure (stderr-reported; stdout
// stays clean for the MCP discipline the parent verb holds).
package main

import "../../cli"
import "core:fmt"
import "core:slice"

// build_mcp_docs_export_command declares `funpack mcp docs-export` — the runtime
// materializer hung under the `mcp` parent verb (build_mcp_command), beside the dev-time
// gen-corpus / gen-contract codegen. One optional `--dir` flag overrides the destination;
// with no flag it writes the version-keyed managed-home tree (docs_export_default).
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

// cli_run_mcp_docs_export is the docs-export handler: materialize → report. Both arms run
// the SAME load+write core (docs_export_into); they differ only in the destination root.
// With --dir the operator owns the path, so the managed-home root resolution is bypassed
// and docs_export_into writes straight into that root (the version is still stamped in the
// sentinel). Without it, docs_export_default resolves the version-keyed managed-home root
// then delegates to the same core. Diagnostics and the success summary go to stderr
// (stdout is reserved for the parent verb's MCP JSON-RPC writer). Returns 0 on success, 1
// on any failure.
cli_run_mcp_docs_export :: proc(inv: ^cli.Cli_Invocation) -> int {
	// The whole run allocates on the HEAP (context.allocator): the corpus is ~520K of
	// section strings and the reconstructed files render another ~520K over the same
	// allocator, which overruns the default scratch temp arena. The process exits after
	// the write, so the per-run leak is bounded and harmless for a one-shot tool.
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
