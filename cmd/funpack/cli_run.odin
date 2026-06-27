package main

import "../../cli"
import "../../funpack"
import funpack_runtime "../../runtime"
import "core:fmt"
import "core:slice"

build_run_command :: proc(allocator := context.allocator) -> ^cli.Cli_Command {
	return cli.cli_new_command(
		cli.Cli_Command {
			use = "run",
			short = "Build the project and play it in one step",
			long = "Build the §14 project tree (like `funpack build`), then launch the built artifact in the live SDL runtime — the one-command build-and-play path. Entrypoint selection by [name] (§14 §6) is not yet implemented: this build runs its single declared entrypoint, so omit the name. Because the first positional is parsed as the (unsupported) [name], record a replay by path with `funpack live <artifact> <replay-out>` instead. To play an ALREADY-built artifact without rebuilding, use `funpack live`.",
			flags = slice.clone(
				[]cli.Cli_Flag {
					{
						name = "release",
						kind = .Bool,
						usage = "Build in release mode (ban typed holes and debug directives) before running",
					},
					{
						name = "seed",
						kind = .Int,
						usage = "Root RNG seed for this run (§25 §60); overrides the entrypoints.fcfg config seed and the fixed engine default. Recorded in the replay header so the run re-folds",
					},
				},
				allocator,
			),
			run = cli_run_run,
		},
		allocator,
	)
}

cli_run_run :: proc(inv: ^cli.Cli_Invocation) -> int {
	extra := cli_run_extra_args(inv)
	forwarded := make([dynamic]string, 0, 2 + len(extra), context.temp_allocator)
	append(&forwarded, ..extra)
	cli.cli_marshal_int_flag(&forwarded, inv, "seed")
	return run_run_verb(cli_run_name(inv), forwarded[:], funpack.cli_build_mode(inv))
}

run_run_verb :: proc(name: string, extra_args: []string, mode: funpack.Build_Mode, root := ".") -> int {
	product, verdict := funpack.stage_build(root, mode, context.temp_allocator)
	if verdict.err != .None {
		funpack.eprint_build_refusal("funpack run", verdict)
		return 2
	}
	if write_err := funpack.write_build_products(product, root); write_err != .None {
		fmt.eprintfln("funpack run: %v", write_err)
		return 2
	}
	if product.artifact_path == "" {
		fmt.eprintln("funpack run: nothing to run — this project declares no entrypoint")
		return 2
	}
	if sel_err := run_select_entrypoint(name); sel_err != "" {
		fmt.eprintfln("funpack run: %s", sel_err)
		return 2
	}
	live_args := make([dynamic]string, 0, 2 + len(extra_args), context.temp_allocator)
	append(&live_args, "funpack run")
	append(&live_args, product.artifact_path)
	append(&live_args, ..extra_args)
	return funpack_runtime.run_live_session(live_args[:])
}

run_select_entrypoint :: proc(name: string) -> (refusal: string) {
	if name == "" {
		return ""
	}
	return fmt.aprintf(
		"entrypoint selection (run %s) is not yet supported — this build runs its single declared entrypoint; omit the name (to record a replay by path, use `funpack live <artifact> <replay-out>`)",
		name,
		allocator = context.temp_allocator,
	)
}

cli_run_name :: proc(inv: ^cli.Cli_Invocation) -> string {
	if len(inv.args) == 0 {
		return ""
	}
	return inv.args[0]
}

cli_run_extra_args :: proc(inv: ^cli.Cli_Invocation) -> []string {
	if len(inv.args) <= 1 {
		return {}
	}
	return inv.args[1:]
}
