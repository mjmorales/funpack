package cli

import "core:strings"
import "core:testing"

@(test)
test_cli_usage_is_deterministic :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)
	a := cli_usage(root, context.temp_allocator)
	b := cli_usage(root, context.temp_allocator)
	testing.expect_value(t, a, b)

	serve := cli_find_subcommand(root, "serve")
	c := cli_usage(serve, context.temp_allocator)
	d := cli_usage(serve, context.temp_allocator)
	testing.expect_value(t, c, d)
}

@(test)
test_cli_usage_parent_block :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)
	usage := cli_usage(root, context.temp_allocator)

	testing.expect(t, strings.contains(usage, "A synthetic test program"))
	testing.expect(t, strings.contains(usage, "Usage:\n  prog [command]"))
	testing.expect(t, strings.contains(usage, "Available Commands:"))
	testing.expect(t, strings.contains(usage, "serve"))
	testing.expect(t, strings.contains(usage, "Serve the thing"))
	testing.expect(t, strings.contains(usage, "build"))
	testing.expect(t, strings.contains(usage, `Use "prog [command] --help" for more information about a command.`))
	testing.expect(t, !strings.contains(usage, "prog [flags]"))
}

@(test)
test_cli_usage_leaf_flags :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)
	serve := cli_find_subcommand(root, "serve")
	usage := cli_usage(serve, context.temp_allocator)

	testing.expect(t, strings.contains(usage, "Usage:\n  prog serve [flags]"))
	testing.expect(t, strings.contains(usage, "Flags:"))
	testing.expect(t, strings.contains(usage, "-p, --port int"))
	testing.expect(t, strings.contains(usage, "-H, --host string"))
	testing.expect(t, strings.contains(usage, "-v, --verbose"))
	testing.expect(t, strings.contains(usage, "-h, --help"))
	testing.expect(t, strings.contains(usage, "help for serve"))
	testing.expect(t, !strings.contains(usage, "Available Commands:"))
}

@(test)
test_cli_usage_args_hint :: proc(t: ^testing.T) {
	root := build_cli_test_tree(context.temp_allocator)
	build := cli_find_subcommand(root, "build")
	usage := cli_usage(build, context.temp_allocator)

	testing.expect(t, strings.contains(usage, "prog build [flags] [args]"))
	testing.expect(t, strings.contains(usage, "-h, --help"))
}
