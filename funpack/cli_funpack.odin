// The concrete funpack command tree — the source main dispatches through. Every
// front-door verb (version, test, build, check, fmt, and the warden index-query
// group) is one Cli_Command node here, its handler a thin adapter that reads the
// resolved flags/positionals and calls the verb's run_X_verb / *_verb_exit core
// — so each verb keeps its documented {0, 1, 2} exit contract (§29 §3); the
// framework owns only the argument plumbing.
//
// Two domain seams keep the generic framework from needing to know funpack's
// types: cli_validate_index_decl_kind is the per-flag predicate that adjudicates
// `warden find --kind` against the closed Index_Decl_Kind member names at parse
// time, and cli_validate_warden_find is the command-level predicate for find's
// "at least one non-empty filter, never an empty name-query" gate (the one
// constraint that is neither a flag nor an arity rule).
package funpack

import "core:reflect"
import "core:slice"

// build_funpack_cli constructs and finalizes the funpack command tree, returning
// its root. The tree is allocated in `allocator` (process-lifetime for main, a
// scratch arena in tests) so every node has a stable address for the parent
// pointers cli_finalize wires. The tree is authored in-repo, so a finalize
// failure is a programmer error, asserted here and pinned by a unit test —
// never a user-facing path.
build_funpack_cli :: proc(allocator := context.allocator) -> ^Cli_Command {
	find := cli_new_command(
		Cli_Command {
			use = "find",
			short = "Look up an existing declaration before writing one",
			long = "Query the project index for a declaration to reuse before implementing one. At least one filter is required — a name substring, a --kind, or a --gtag; an empty result means nothing to reuse.",
			flags = slice.clone(
				[]Cli_Flag {
					{
						name = "kind",
						kind = .String,
						usage = "Restrict to an exact Index_Decl_Kind (e.g. Fn, Thing, Signal)",
						validate = cli_validate_index_decl_kind,
					},
					{
						name = "gtag",
						kind = .String,
						usage = "Restrict to declarations carrying a governance tag",
						validate = cli_nonempty,
					},
				},
				allocator,
			),
			args = cli_range_args(0, 1),
			validate = cli_validate_warden_find,
			run = cli_run_warden_find,
		},
		allocator,
	)
	holes := cli_new_command(
		Cli_Command {
			use = "holes",
			short = "List every typed hole in the index",
			args = cli_no_args(),
			run = cli_run_warden_holes,
		},
		allocator,
	)
	probes := cli_new_command(
		Cli_Command {
			use = "probes",
			short = "List every debug probe in the index",
			args = cli_no_args(),
			run = cli_run_warden_probes,
		},
		allocator,
	)
	debt := cli_new_command(
		Cli_Command {
			use = "debt",
			short = "List declarations tagged as debt",
			args = cli_no_args(),
			run = cli_run_warden_debt,
		},
		allocator,
	)
	graph := cli_new_command(
		Cli_Command {
			use = "graph",
			short = "Print the dependency graph, optionally filtered to one node's edges",
			args = cli_range_args(0, 1),
			run = cli_run_warden_graph,
		},
		allocator,
	)
	tags := cli_new_command(
		Cli_Command {
			use = "tags",
			short = "List the registered governance tags",
			args = cli_no_args(),
			run = cli_run_warden_tags,
		},
		allocator,
	)
	pipeline := cli_new_command(
		Cli_Command {
			use = "pipeline",
			short = "Print the pipeline projection from the index",
			args = cli_no_args(),
			run = cli_run_warden_pipeline,
		},
		allocator,
	)
	warden := cli_new_command(
		Cli_Command {
			use = "warden",
			short = "Query the committed project index (read-only)",
			long = "The warden sub-toolchain answers pure index queries over the emitted .funpack/index.ndjson. Every subcommand refuses with exit 2 when the index is missing, schema-mismatched, or malformed; none recompiles in its place.",
			subcommands = slice.clone(
				[]^Cli_Command{find, holes, probes, debt, graph, tags, pipeline},
				allocator,
			),
		},
		allocator,
	)

	version := cli_new_command(
		Cli_Command {
			use = "version",
			short = "Print the toolchain version and schema surface",
			args = cli_no_args(),
			run = cli_run_version,
		},
		allocator,
	)
	test := cli_new_command(
		Cli_Command {
			use = "test",
			short = "Run every test block in the project tree",
			args = cli_no_args(),
			run = cli_run_test,
		},
		allocator,
	)
	build := cli_new_command(
		Cli_Command {
			use = "build",
			short = "Compile the project tree and write its artifacts",
			flags = slice.clone(
				[]Cli_Flag {
					{
						name = "release",
						kind = .Bool,
						usage = "Ban typed holes and debug directives (the shippable build)",
					},
				},
				allocator,
			),
			args = cli_no_args(),
			run = cli_run_build,
		},
		allocator,
	)
	run := cli_new_command(
		Cli_Command {
			use = "run",
			short = "Build the project and run it with the funpack-live runtime",
			long = "Build the §14 project tree (like `funpack build`), then launch the built artifact with the separate funpack-live runtime — the one-command build-and-play path. The optional [name] selects an entrypoint (§14 §6); any further positionals are forwarded to funpack-live (e.g. a replay-out path). funpack stays the pure compiler: run only spawns the runtime, never links it.",
			flags = slice.clone(
				[]Cli_Flag {
					{
						name = "release",
						kind = .Bool,
						usage = "Build in release mode (ban typed holes and debug directives) before running",
					},
				},
				allocator,
			),
			run = cli_run_run,
		},
		allocator,
	)
	check := cli_new_command(
		Cli_Command {
			use = "check",
			short = "Adjudicate the project tree, writing no products",
			flags = slice.clone(
				[]Cli_Flag {
					{
						name = "release",
						kind = .Bool,
						usage = "Ban typed holes and debug directives (shippability verdict)",
					},
				},
				allocator,
			),
			args = cli_no_args(),
			run = cli_run_check,
		},
		allocator,
	)
	fmt_cmd := cli_new_command(
		Cli_Command {
			use = "fmt",
			short = "Rewrite authored sources to canonical form",
			flags = slice.clone(
				[]Cli_Flag {
					{
						name = "check",
						kind = .Bool,
						usage = "Report drift and write nothing (verdict-only)",
					},
				},
				allocator,
			),
			args = cli_no_args(),
			run = cli_run_fmt,
		},
		allocator,
	)

	root := cli_new_command(
		Cli_Command {
			use = "funpack",
			short = "The funpack source → artifact compiler",
			long = "funpack compiles a §14 project tree to its versioned artifacts: a runnable game artifact and the Index Contract NDJSON. Pure — no clock, no DB, no network in scope.",
			subcommands = slice.clone(
				[]^Cli_Command{version, test, build, run, check, fmt_cmd, warden},
				allocator,
			),
		},
		allocator,
	)
	ok, message := cli_finalize(root)
	assert(ok, message)
	return root
}

// cli_new_command heap-copies a command spec into `allocator` and returns its
// stable address — the addressable node cli_finalize threads parent pointers
// through and subcommand slices reference.
cli_new_command :: proc(spec: Cli_Command, allocator := context.allocator) -> ^Cli_Command {
	cmd := new(Cli_Command, allocator)
	cmd^ = spec
	return cmd
}

// ── verb handlers ────────────────────────────────────────────────────────────
// Each handler is the adapter from a resolved invocation to a run_X_verb core.
// Verbs that read no flags/positionals ignore the invocation (the `_` parameter
// makes that explicit); build/check/fmt/find/graph project the invocation onto
// the verb's existing mode/query type through the mappers below.

cli_run_version :: proc(_: ^Cli_Invocation) -> int {
	return run_version_verb()
}

cli_run_test :: proc(_: ^Cli_Invocation) -> int {
	return run_test_verb()
}

cli_run_build :: proc(inv: ^Cli_Invocation) -> int {
	return run_build_verb(cli_build_mode(inv))
}

cli_run_check :: proc(inv: ^Cli_Invocation) -> int {
	return run_check_verb(".", cli_build_mode(inv))
}

// cli_run_run adapts the `funpack run` invocation onto run_run_verb: the
// `--release` flag maps to the build mode (the same cli_build_mode build/check
// share), the first positional is the optional [name] entrypoint pick, and every
// later positional is forwarded verbatim to funpack-live (cli_run_name /
// cli_run_extra_args). run_run_verb owns the {1, 2, child-code} exit contract.
cli_run_run :: proc(inv: ^Cli_Invocation) -> int {
	return run_run_verb(cli_run_name(inv), cli_run_extra_args(inv), cli_build_mode(inv))
}

cli_run_fmt :: proc(inv: ^Cli_Invocation) -> int {
	return run_fmt_verb(cli_fmt_mode(inv))
}

cli_run_warden_find :: proc(inv: ^Cli_Invocation) -> int {
	return run_warden_verb(.Find, "", cli_warden_find_query(inv))
}

cli_run_warden_holes :: proc(_: ^Cli_Invocation) -> int {
	return run_warden_verb(.Holes, "", {})
}

cli_run_warden_probes :: proc(_: ^Cli_Invocation) -> int {
	return run_warden_verb(.Probes, "", {})
}

cli_run_warden_debt :: proc(_: ^Cli_Invocation) -> int {
	return run_warden_verb(.Debt, "", {})
}

cli_run_warden_tags :: proc(_: ^Cli_Invocation) -> int {
	return run_warden_verb(.Tags, "", {})
}

cli_run_warden_pipeline :: proc(_: ^Cli_Invocation) -> int {
	return run_warden_verb(.Pipeline, "", {})
}

cli_run_warden_graph :: proc(inv: ^Cli_Invocation) -> int {
	arg := ""
	if len(inv.args) == 1 {
		arg = inv.args[0]
	}
	return run_warden_verb(.Graph, arg, {})
}

// ── invocation → verb-type mappers ───────────────────────────────────────────

// cli_build_mode maps the build/check `--release` flag to its Build_Mode: the
// flag present is Release (the §29 §4 hole-ban mode), absent is Dev. Both build
// and check read `--release` through this mapper.
cli_build_mode :: proc(inv: ^Cli_Invocation) -> Build_Mode {
	return .Release if cli_flag_bool(inv, "release") else .Dev
}

// cli_fmt_mode maps the fmt `--check` flag to its Fmt_Mode: present is the
// verdict-only Check face, absent is the in-place Write face.
cli_fmt_mode :: proc(inv: ^Cli_Invocation) -> Fmt_Mode {
	return .Check if cli_flag_bool(inv, "check") else .Write
}

// cli_run_name reads `funpack run`'s optional [name] entrypoint pick — the FIRST
// positional, "" when none was given (the implicit single-entrypoint default per
// §14 §6). The remaining positionals are funpack-live's forwarded args
// (cli_run_extra_args), so the name and the forwarded args partition the positional
// list at index 0.
cli_run_name :: proc(inv: ^Cli_Invocation) -> string {
	if len(inv.args) == 0 {
		return ""
	}
	return inv.args[0]
}

// cli_run_extra_args reads the positionals AFTER the optional [name] — the args
// forwarded verbatim to funpack-live (e.g. a replay-out path). With no positionals
// the slice is empty; with one it is empty (that one is the name); with more it is
// the tail past the name.
cli_run_extra_args :: proc(inv: ^Cli_Invocation) -> []string {
	if len(inv.args) <= 1 {
		return {}
	}
	return inv.args[1:]
}

// cli_warden_find_query projects the find invocation onto its Warden_Find_Query:
// the optional positional becomes the name substring, and the validated --kind /
// --gtag flags become the kind/gtag filters ("" when absent — the sentinel the
// query treats as "filter not provided").
cli_warden_find_query :: proc(inv: ^Cli_Invocation) -> Warden_Find_Query {
	query: Warden_Find_Query
	if len(inv.args) == 1 {
		query.name = inv.args[0]
	}
	query.kind = cli_flag_string(inv, "kind")
	query.gtag = cli_flag_string(inv, "gtag")
	return query
}

// ── domain validators ────────────────────────────────────────────────────────

// cli_validate_index_decl_kind is the `warden find --kind` value predicate: the
// value must be an EXACT Index_Decl_Kind member name (reflect.enum_from_name —
// never case-folded, never fuzzy), so an unknown kind is a usage error at parse,
// before any index read.
cli_validate_index_decl_kind :: proc(value: string) -> bool {
	_, known := reflect.enum_from_name(Index_Decl_Kind, value)
	return known
}

// cli_validate_warden_find is find's command-level gate: find answers a lookup,
// not an index dump, so it requires at least one filter — a name, a --kind, or a
// --gtag — and rejects an explicitly-empty name-query (a disguised dump). Run
// over the fully bound invocation after arity, so an over-long positional list
// is already a Bad_Arg_Count by the time this sees it.
cli_validate_warden_find :: proc(inv: ^Cli_Invocation) -> bool {
	if len(inv.args) == 1 && inv.args[0] == "" {
		return false
	}
	has_name := len(inv.args) == 1
	has_kind := cli_flag_string(inv, "kind") != ""
	has_gtag := cli_flag_string(inv, "gtag") != ""
	return has_name || has_kind || has_gtag
}
