package funpack

import "../cli"
import "core:reflect"
import "core:slice"

build_funpack_compiler_subtree :: proc(allocator := context.allocator) -> []^cli.Cli_Command {
	find := cli.cli_new_command(
		cli.Cli_Command {
			use = "find",
			short = "Look up an existing declaration before writing one",
			long = "Query the project index for a declaration to reuse before implementing one. At least one filter is required — a name substring, a --kind, or a --gtag; an empty result means nothing to reuse.",
			flags = slice.clone(
				[]cli.Cli_Flag {
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
						validate = cli.cli_nonempty,
					},
				},
				allocator,
			),
			args = cli.cli_range_args(0, 1),
			validate = cli_validate_warden_find,
			run = cli_run_warden_find,
		},
		allocator,
	)
	holes := cli.cli_new_command(
		cli.Cli_Command {
			use = "holes",
			short = "List every typed hole in the index",
			args = cli.cli_no_args(),
			run = cli_run_warden_holes,
		},
		allocator,
	)
	probes := cli.cli_new_command(
		cli.Cli_Command {
			use = "probes",
			short = "List every debug probe in the index",
			args = cli.cli_no_args(),
			run = cli_run_warden_probes,
		},
		allocator,
	)
	debt := cli.cli_new_command(
		cli.Cli_Command {
			use = "debt",
			short = "List declarations tagged as debt",
			args = cli.cli_no_args(),
			run = cli_run_warden_debt,
		},
		allocator,
	)
	graph := cli.cli_new_command(
		cli.Cli_Command {
			use = "graph",
			short = "Print the dependency graph, optionally filtered to one node's edges",
			args = cli.cli_range_args(0, 1),
			run = cli_run_warden_graph,
		},
		allocator,
	)
	tags := cli.cli_new_command(
		cli.Cli_Command {
			use = "tags",
			short = "List the registered governance tags",
			args = cli.cli_no_args(),
			run = cli_run_warden_tags,
		},
		allocator,
	)
	pipeline := cli.cli_new_command(
		cli.Cli_Command {
			use = "pipeline",
			short = "Print the pipeline projection from the index",
			args = cli.cli_no_args(),
			run = cli_run_warden_pipeline,
		},
		allocator,
	)
	warden := cli.cli_new_command(
		cli.Cli_Command {
			use = "warden",
			short = "Query the committed project index (read-only)",
			long = "The warden sub-toolchain answers pure index queries over the emitted .funpack/index.ndjson. Every subcommand refuses with exit 2 when the index is missing, schema-mismatched, or malformed; none recompiles in its place.",
			subcommands = slice.clone(
				[]^cli.Cli_Command{find, holes, probes, debt, graph, tags, pipeline},
				allocator,
			),
		},
		allocator,
	)

	version := cli.cli_new_command(
		cli.Cli_Command {
			use = "version",
			short = "Print the toolchain version and schema surface",
			flags = slice.clone(
				[]cli.Cli_Flag {
					{
						name = "json",
						kind = .Bool,
						usage = "Emit the machine-readable JSON contract shape (for tooling)",
					},
				},
				allocator,
			),
			args = cli.cli_no_args(),
			run = cli_run_version,
		},
		allocator,
	)
	introspect := cli.cli_new_command(
		cli.Cli_Command {
			use = "introspect",
			short = "Dump the live stdlib surface as byte-stable JSON (read-only)",
			long = "Emit the compiler-authoritative stdlib surface — the modules and decls, the §26 §3 re-exports, the typed free-function signatures, the engine-enum variant sets, the struct-payload variants, and the receiver/static/associated method surfaces — as one deterministic JSON object generated FROM the live surface.odin tables `check` enforces against. Use it to regenerate the docs corpus mechanically, or as ground truth when the corpus and the compiler disagree.",
			args = cli.cli_no_args(),
			run = cli_run_introspect,
		},
		allocator,
	)
	test := cli.cli_new_command(
		cli.Cli_Command {
			use = "test",
			short = "Run every test block in the project tree",
			args = cli.cli_no_args(),
			run = cli_run_test,
		},
		allocator,
	)
	build := cli.cli_new_command(
		cli.Cli_Command {
			use = "build",
			short = "Compile the project tree and write its artifacts",
			flags = slice.clone(
				[]cli.Cli_Flag {
					{
						name = "release",
						kind = .Bool,
						usage = "Ban typed holes and debug directives (the shippable build)",
					},
				},
				allocator,
			),
			args = cli.cli_no_args(),
			run = cli_run_build,
		},
		allocator,
	)
	check := cli.cli_new_command(
		cli.Cli_Command {
			use = "check",
			short = "Adjudicate the project tree, writing no products",
			long = "Adjudicate the §14 project tree through the full checked pipeline and write no products (exit 0 clean, 2 for any compile/gate failure). With --recursive it sweeps a directory tree, discovering and checking every funpack_configs project under [root] (default cwd) in one invocation — one verdict line per project plus an aggregate summary, exit 2 if any project fails (named).",
			flags = slice.clone(
				[]cli.Cli_Flag {
					{
						name = "release",
						kind = .Bool,
						usage = "Ban typed holes and debug directives (shippability verdict)",
					},
					{
						name = "recursive",
						shorthand = 'r',
						kind = .Bool,
						usage = "Discover and check every funpack_configs project under [root]",
					},
				},
				allocator,
			),
			args = cli.cli_range_args(0, 1),
			run = cli_run_check,
		},
		allocator,
	)
	fmt_cmd := cli.cli_new_command(
		cli.Cli_Command {
			use = "fmt",
			short = "Rewrite authored sources to canonical form",
			flags = slice.clone(
				[]cli.Cli_Flag {
					{
						name = "check",
						kind = .Bool,
						usage = "Report drift and write nothing (verdict-only)",
					},
				},
				allocator,
			),
			args = cli.cli_no_args(),
			run = cli_run_fmt,
		},
		allocator,
	)

	return slice.clone(
		[]^cli.Cli_Command{version, introspect, test, build, check, fmt_cmd, warden},
		allocator,
	)
}

cli_run_version :: proc(inv: ^cli.Cli_Invocation) -> int {
	return run_version_verb(cli.cli_flag_bool(inv, "json"))
}

cli_run_introspect :: proc(_: ^cli.Cli_Invocation) -> int {
	return run_introspect_verb()
}

cli_run_test :: proc(_: ^cli.Cli_Invocation) -> int {
	return run_test_verb()
}

cli_run_build :: proc(inv: ^cli.Cli_Invocation) -> int {
	return run_build_verb(cli_build_mode(inv))
}

cli_run_check :: proc(inv: ^cli.Cli_Invocation) -> int {
	root := inv.args[0] if len(inv.args) == 1 else "."
	if cli.cli_flag_bool(inv, "recursive") {
		return run_check_recursive_verb(root, cli_build_mode(inv))
	}
	return run_check_verb(root, cli_build_mode(inv))
}

cli_run_fmt :: proc(inv: ^cli.Cli_Invocation) -> int {
	return run_fmt_verb(cli_fmt_mode(inv))
}

cli_run_warden_find :: proc(inv: ^cli.Cli_Invocation) -> int {
	return run_warden_verb(.Find, "", cli_warden_find_query(inv))
}

cli_run_warden_holes :: proc(_: ^cli.Cli_Invocation) -> int {
	return run_warden_verb(.Holes, "", {})
}

cli_run_warden_probes :: proc(_: ^cli.Cli_Invocation) -> int {
	return run_warden_verb(.Probes, "", {})
}

cli_run_warden_debt :: proc(_: ^cli.Cli_Invocation) -> int {
	return run_warden_verb(.Debt, "", {})
}

cli_run_warden_tags :: proc(_: ^cli.Cli_Invocation) -> int {
	return run_warden_verb(.Tags, "", {})
}

cli_run_warden_pipeline :: proc(_: ^cli.Cli_Invocation) -> int {
	return run_warden_verb(.Pipeline, "", {})
}

cli_run_warden_graph :: proc(inv: ^cli.Cli_Invocation) -> int {
	arg := ""
	if len(inv.args) == 1 {
		arg = inv.args[0]
	}
	return run_warden_verb(.Graph, arg, {})
}

cli_build_mode :: proc(inv: ^cli.Cli_Invocation) -> Build_Mode {
	return .Release if cli.cli_flag_bool(inv, "release") else .Dev
}

cli_fmt_mode :: proc(inv: ^cli.Cli_Invocation) -> Fmt_Mode {
	return .Check if cli.cli_flag_bool(inv, "check") else .Write
}

cli_warden_find_query :: proc(inv: ^cli.Cli_Invocation) -> Warden_Find_Query {
	query: Warden_Find_Query
	if len(inv.args) == 1 {
		query.name = inv.args[0]
	}
	query.kind = cli.cli_flag_string(inv, "kind")
	query.gtag = cli.cli_flag_string(inv, "gtag")
	return query
}

cli_validate_index_decl_kind :: proc(value: string) -> bool {
	_, known := reflect.enum_from_name(Index_Decl_Kind, value)
	return known
}

cli_validate_warden_find :: proc(inv: ^cli.Cli_Invocation) -> bool {
	if len(inv.args) == 1 && inv.args[0] == "" {
		return false
	}
	has_name := len(inv.args) == 1
	has_kind := cli.cli_flag_string(inv, "kind") != ""
	has_gtag := cli.cli_flag_string(inv, "gtag") != ""
	return has_name || has_kind || has_gtag
}
