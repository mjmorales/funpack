package main

import "../../cli"
import "../../funpack"
import funpack_runtime "../../runtime"
import "core:fmt"
import "core:slice"

build_render_check_command :: proc(allocator := context.allocator) -> ^cli.Cli_Command {
	return cli.cli_new_command(
		cli.Cli_Command {
			use = "render-check",
			short = "Build the project and assert it renders something (catch a black screen)",
			long = "Build the §14 project tree (like `funpack build`), then fold the built artifact headlessly from a cold seeded startup and assert the §20 draw-list is non-empty on at least one of the first N ticks. This is the integration seam unit tests cannot cover: a check-clean, test-green build can still ship a black screen because pure-fn tests never run the live thing/pipeline/render wiring. Exit 0 = drew, exit 1 = drew nothing across the whole window (a black screen), exit 2 = build refusal or no entrypoint. Widen --ticks for a game that legitimately renders nothing for its opening frames.",
			flags = slice.clone(
				[]cli.Cli_Flag {
					{
						name = "release",
						kind = .Bool,
						usage = "Build in release mode (ban typed holes and debug directives) before checking",
					},
					{
						name = "ticks",
						kind = .Int,
						usage = "Cold-start window to fold (default 64); widen it for a game whose first draw is delayed",
					},
					{
						name = "seed",
						kind = .Int,
						usage = "Root RNG seed for the fold (§25 §60); overrides the entrypoints.fcfg config seed and the fixed engine default",
					},
				},
				allocator,
			),
			run = cli_run_render_check,
		},
		allocator,
	)
}

cli_run_render_check :: proc(inv: ^cli.Cli_Invocation) -> int {
	ticks := funpack_runtime.RENDER_CHECK_DEFAULT_TICKS
	if _, passed := inv.flags["ticks"]; passed {
		ticks = cli.cli_flag_int(inv, "ticks")
	}
	seed_override: Maybe(i64) = nil
	if _, passed := inv.flags["seed"]; passed {
		seed_override = i64(cli.cli_flag_int(inv, "seed"))
	}
	return run_render_check_verb(funpack.cli_build_mode(inv), ticks, seed_override)
}

run_render_check_verb :: proc(
	mode: funpack.Build_Mode,
	ticks: int,
	seed_override: Maybe(i64),
	root := ".",
) -> int {
	product, verdict := funpack.stage_build(root, mode, context.temp_allocator)
	if verdict.err != .None {
		funpack.eprint_build_refusal("funpack render-check", verdict)
		return 2
	}
	if write_err := funpack.write_build_products(product, root); write_err != .None {
		fmt.eprintfln("funpack render-check: %v", write_err)
		return 2
	}
	if product.artifact_path == "" {
		fmt.eprintln("funpack render-check: nothing to render — this project declares no entrypoint")
		return 2
	}

	report, open_result := funpack_runtime.render_check_artifact(
		product.artifact_path,
		ticks,
		seed_override,
		context.temp_allocator,
	)
	if open_result != .Ok {
		fmt.eprintfln("funpack render-check: could not load the built artifact (%v)", open_result)
		return 2
	}

	if !report.drew && !report.has_render_stage {
		fmt.printfln(
			"funpack render-check: N/A — this project declares no render: stage, so there is no §20 draw-list to assert (a ui-only or non-visual project).",
		)
		return 0
	}

	if !report.drew {
		fmt.eprintfln(
			"funpack render-check: BLACK SCREEN — the game has a render: stage but drew nothing across %d ticks from a %s cold start. The build is check-clean and may be test-green, but the live pipeline renders an empty draw-list (the live present path projects through this same fold). Check that a thing occupying the render stage is actually spawned (and seeded, if it uses Rng), or widen --ticks if the first frame is genuinely delayed.",
			report.ticks,
			report.seeded ? "seeded" : "seedless",
		)
		return 1
	}

	fmt.printfln(
		"funpack render-check: OK — first drew at %s, %d draw commands over %d ticks (%s).",
		render_check_frame_label(report.first_drawn_frame),
		report.total_cmds,
		report.ticks,
		report.seeded ? "seeded" : "seedless",
	)
	return 0
}

render_check_frame_label :: proc(frame: int) -> string {
	if frame < 0 {
		return "the opening frame"
	}
	return fmt.tprintf("tick %d", frame)
}
