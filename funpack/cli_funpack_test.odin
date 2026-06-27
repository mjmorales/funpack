package funpack

import "../cli"
import "core:testing"

build_compiler_test_root :: proc(allocator := context.temp_allocator) -> ^cli.Cli_Command {
	root := cli.cli_new_command(
		cli.Cli_Command {
			use = "funpack",
			short = "The funpack source → artifact compiler",
			subcommands = build_funpack_compiler_subtree(allocator),
		},
		allocator,
	)
	cli.cli_finalize(root)
	return root
}

expect_funpack_ok :: proc(
	t: ^testing.T,
	root: ^cli.Cli_Command,
	argv: []string,
	loc := #caller_location,
) -> cli.Cli_Invocation {
	inv, err := cli.cli_parse(root, argv, context.temp_allocator)
	testing.expect_value(t, err.kind, cli.Cli_Parse_Error_Kind.None, loc = loc)
	return inv
}

expect_funpack_reject :: proc(
	t: ^testing.T,
	root: ^cli.Cli_Command,
	argv: []string,
	loc := #caller_location,
) {
	_, err := cli.cli_parse(root, argv, context.temp_allocator)
	testing.expect(t, err.kind != .None, "expected a usage rejection", loc = loc)
}

@(test)
test_funpack_tree_finalizes :: proc(t: ^testing.T) {
	root := build_compiler_test_root()
	ok, message := cli.cli_finalize(root)
	testing.expect(t, ok, message)
}

@(test)
test_funpack_top_level_verbs :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	testing.expect_value(t, expect_funpack_ok(t, root, {"version"}).command.use, "version")
	testing.expect_value(t, expect_funpack_ok(t, root, {"test"}).command.use, "test")
	testing.expect_value(t, expect_funpack_ok(t, root, {"introspect"}).command.use, "introspect")

	expect_funpack_reject(t, root, {})
	expect_funpack_reject(t, root, {"bogus"})
	expect_funpack_reject(t, root, {"version", "extra"})
	expect_funpack_reject(t, root, {"test", "--flag"})
}

@(test)
test_funpack_introspect_verb :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	inv := expect_funpack_ok(t, root, {"introspect"})
	testing.expect_value(t, inv.command.use, "introspect")
	testing.expect_value(t, len(inv.args), 0)
	testing.expect(t, inv.command.run == cli_run_introspect, "introspect routes to its dump core")

	expect_funpack_reject(t, root, {"introspect", "extra"})
	expect_funpack_reject(t, root, {"introspect", "--json"})
}

@(test)
test_funpack_version_json_flag :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	inv := expect_funpack_ok(t, root, {"version"})
	testing.expect(t, !cli.cli_flag_bool(&inv, "json"), "bare version is the human face")

	inv = expect_funpack_ok(t, root, {"version", "--json"})
	testing.expect(t, cli.cli_flag_bool(&inv, "json"), "--json selects the machine face")

	expect_funpack_reject(t, root, {"version", "--jsn"})
	expect_funpack_reject(t, root, {"version", "--json", "extra"})
}

@(test)
test_funpack_build_release_flag :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	inv := expect_funpack_ok(t, root, {"build"})
	testing.expect_value(t, cli_build_mode(&inv), Build_Mode.Dev)

	inv = expect_funpack_ok(t, root, {"build", "--release"})
	testing.expect_value(t, cli_build_mode(&inv), Build_Mode.Release)

	inv = expect_funpack_ok(t, root, {"check", "--release"})
	testing.expect_value(t, cli_build_mode(&inv), Build_Mode.Release)

	expect_funpack_reject(t, root, {"build", "--relase"})
	expect_funpack_reject(t, root, {"build", "--release", "extra"})
	expect_funpack_reject(t, root, {"check", "--relase"})
}

@(test)
test_funpack_check_recursive_flag :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	inv := expect_funpack_ok(t, root, {"check"})
	testing.expect_value(t, cli.cli_flag_bool(&inv, "recursive"), false)
	testing.expect_value(t, len(inv.args), 0)

	inv = expect_funpack_ok(t, root, {"check", "--recursive", "games"})
	testing.expect_value(t, cli.cli_flag_bool(&inv, "recursive"), true)
	testing.expect_value(t, len(inv.args), 1)
	testing.expect_value(t, inv.args[0], "games")

	inv = expect_funpack_ok(t, root, {"check", "-r", "games"})
	testing.expect_value(t, cli.cli_flag_bool(&inv, "recursive"), true)
	testing.expect_value(t, inv.args[0], "games")

	inv = expect_funpack_ok(t, root, {"check", "--recursive", "--release", "games"})
	testing.expect_value(t, cli.cli_flag_bool(&inv, "recursive"), true)
	testing.expect_value(t, cli_build_mode(&inv), Build_Mode.Release)

	inv = expect_funpack_ok(t, root, {"check", "games"})
	testing.expect_value(t, cli.cli_flag_bool(&inv, "recursive"), false)
	testing.expect_value(t, inv.args[0], "games")

	expect_funpack_reject(t, root, {"check", "--recursiv"})
	expect_funpack_reject(t, root, {"check", "--recursive", "a", "b"})
}

@(test)
test_funpack_fmt_check_flag :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	inv := expect_funpack_ok(t, root, {"fmt"})
	testing.expect_value(t, cli_fmt_mode(&inv), Fmt_Mode.Write)

	inv = expect_funpack_ok(t, root, {"fmt", "--check"})
	testing.expect_value(t, cli_fmt_mode(&inv), Fmt_Mode.Check)

	expect_funpack_reject(t, root, {"fmt", "--chek"})
	expect_funpack_reject(t, root, {"fmt", "--check", "extra"})
}

@(test)
test_funpack_warden_subcommand_totality :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	argless := []string{"holes", "probes", "debt", "tags", "pipeline"}
	for name in argless {
		inv := expect_funpack_ok(t, root, {"warden", name})
		testing.expect_value(t, inv.command.use, name)
		testing.expect_value(t, len(inv.args), 0)
	}

	expect_funpack_reject(t, root, {"warden"})
	expect_funpack_reject(t, root, {"warden", "fnid"})
	expect_funpack_reject(t, root, {"warden", "tags", "extra"})
}

@(test)
test_funpack_warden_graph_positional :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	inv := expect_funpack_ok(t, root, {"warden", "graph", "drift.damped"})
	testing.expect_value(t, inv.command.use, "graph")
	testing.expect_value(t, len(inv.args), 1)
	testing.expect_value(t, inv.args[0], "drift.damped")

	expect_funpack_reject(t, root, {"warden", "graph", "drift.damped", "extra"})
	expect_funpack_reject(t, root, {"warden", "holes", "drift.damped"})
	expect_funpack_reject(t, root, {"warden", "pipeline", "drift.damped"})
}

@(test)
test_funpack_warden_find_query :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	inv := expect_funpack_ok(t, root, {"warden", "find", "damped"})
	testing.expect_value(t, cli_warden_find_query(&inv), Warden_Find_Query{name = "damped"})

	inv = expect_funpack_ok(t, root, {"warden", "find", "--kind", "Extern_Fn"})
	testing.expect_value(t, cli_warden_find_query(&inv), Warden_Find_Query{kind = "Extern_Fn"})

	inv = expect_funpack_ok(t, root, {"warden", "find", "--gtag", "debt"})
	testing.expect_value(t, cli_warden_find_query(&inv), Warden_Find_Query{gtag = "debt"})

	inv = expect_funpack_ok(t, root, {"warden", "find", "damped", "--kind", "Fn", "--gtag", "physics"})
	testing.expect_value(
		t,
		cli_warden_find_query(&inv),
		Warden_Find_Query{name = "damped", kind = "Fn", gtag = "physics"},
	)
}

@(test)
test_funpack_warden_find_rejections :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	rejected := [][]string {
		{"warden", "find"},
		{"warden", "find", "--kind", "fn"},
		{"warden", "find", "--kind", "Widget"},
		{"warden", "find", "--kind"},
		{"warden", "find", "--gtag"},
		{"warden", "find", "--gtag", ""},
		{"warden", "find", ""},
		{"warden", "find", "a", "b"},
		{"warden", "find", "--kind", "Fn", "--kind", "Fn"},
		{"warden", "find", "--glob", "x"},
	}
	for shape in rejected {
		expect_funpack_reject(t, root, shape)
	}
}

@(test)
test_funpack_help_requested :: proc(t: ^testing.T) {
	root := build_compiler_test_root()

	inv, err := cli.cli_parse(root, {"--help"}, context.temp_allocator)
	testing.expect_value(t, err.kind, cli.Cli_Parse_Error_Kind.None)
	testing.expect(t, inv.help)
	testing.expect_value(t, inv.command.use, "funpack")

	inv, err = cli.cli_parse(root, {"build", "-h"}, context.temp_allocator)
	testing.expect_value(t, err.kind, cli.Cli_Parse_Error_Kind.None)
	testing.expect(t, inv.help)
	testing.expect_value(t, inv.command.use, "build")

	inv, err = cli.cli_parse(root, {"warden", "--help"}, context.temp_allocator)
	testing.expect_value(t, err.kind, cli.Cli_Parse_Error_Kind.None)
	testing.expect(t, inv.help)
	testing.expect_value(t, inv.command.use, "warden")
}
