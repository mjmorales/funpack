package main

import "../../cli"
import "../../funpack"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_run_dispatch :: proc(t: ^testing.T) {
	root := build_root_cli(context.temp_allocator)
	cli.cli_finalize(root)

	inv := expect_root_ok(t, root, {"run"})
	testing.expect_value(t, inv.command.use, "run")
	testing.expect_value(t, funpack.cli_build_mode(&inv), funpack.Build_Mode.Dev)
	testing.expect_value(t, cli_run_name(&inv), "")
	testing.expect_value(t, len(cli_run_extra_args(&inv)), 0)

	inv = expect_root_ok(t, root, {"run", "--release"})
	testing.expect_value(t, funpack.cli_build_mode(&inv), funpack.Build_Mode.Release)
	testing.expect_value(t, cli_run_name(&inv), "")

	inv = expect_root_ok(t, root, {"run", "main", "out.replay", "extra"})
	testing.expect_value(t, cli_run_name(&inv), "main")
	extra := cli_run_extra_args(&inv)
	testing.expect_value(t, len(extra), 2)
	testing.expect_value(t, extra[0], "out.replay")
	testing.expect_value(t, extra[1], "extra")

	expect_root_reject(t, root, {"run", "--relase"})
}

@(test)
test_live_attach_dispatch :: proc(t: ^testing.T) {
	root := build_root_cli(context.temp_allocator)
	cli.cli_finalize(root)

	testing.expect_value(t, len(expect_root_ok(t, root, {"live", "art"}).args), 1)
	testing.expect_value(t, len(expect_root_ok(t, root, {"live", "art", "out.replay"}).args), 2)
	expect_root_reject(t, root, {"live"})
	expect_root_reject(t, root, {"live", "a", "b", "c"})

	inv := expect_root_ok(t, root, {"attach", "art", "--port", "9000"})
	testing.expect_value(t, cli.cli_flag_int(&inv, "port"), 9000)
	expect_root_reject(t, root, {"attach"})
	expect_root_reject(t, root, {"attach", "art", "--port", "notint"})
}

@(test)
test_run_select_entrypoint :: proc(t: ^testing.T) {
	testing.expect_value(t, run_select_entrypoint(""), "")
	refusal := run_select_entrypoint("boss-rush")
	testing.expect(t, strings.contains(refusal, "not yet supported"))
	testing.expect(t, strings.contains(refusal, "boss-rush"))
	testing.expect(t, strings.contains(refusal, "funpack live"))

	cmd := build_run_command(context.temp_allocator)
	testing.expect(t, strings.contains(cmd.long, "not yet implemented"))
	testing.expect(t, strings.contains(cmd.long, "funpack live <artifact> <replay-out>"))
}

@(test)
test_run_build_refusal :: proc(t: ^testing.T) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	dir, _ := filepath.join({base, "funpack-cmd-run-refusal"}, context.temp_allocator)
	if os.make_directory(dir) != nil && !os.exists(dir) {
		return
	}
	defer os.remove_all(dir)

	testing.expect_value(t, run_run_verb("", {}, funpack.Build_Mode.Dev, dir), 2)
}
