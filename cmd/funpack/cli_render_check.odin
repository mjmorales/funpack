// The `funpack render-check` verb: build the §14 project tree, then fold the
// freshly-built artifact HEADLESSLY for N ticks from a cold seeded startup and
// assert the projected §20 draw-list is non-empty on at least one frame. It is
// the "green ≠ works" integration seam (decision
// 2026-06-25-single-spawn-things-are-legit-things): a check-clean,
// 100%-test-green build can still ship a black screen, because unit tests fold
// pure behavior fns in isolation and never run the live thing → pipeline →
// render wiring. This verb runs exactly that wiring and fails when the game
// draws nothing.
//
// THE LAUNCH: the build half is the same pure funpack.stage_build the build and
// run verbs compile; the check half is a direct in-process call into
// funpack_runtime.render_check_artifact — no SDL window, no display, no child
// process. Render is a deterministic post-commit projection (§20 §5), so the
// fold needs no present boundary; the verb links SDL only because this entry
// package does, never because the check uses it.
//
// THE EXIT CONTRACT (spec §29 §3):
//   - A build/gate/tree refusal is exit 2 with the SAME eprint_build_refusal
//     block build prints (a compile error is never a counted check failure).
//   - A host IO failure writing the products, a PACKAGE with no entrypoint
//     (nothing to render), or an internal artifact-open fault is exit 2.
//   - A clean build that DREW at least one command in the window is exit 0.
//   - A clean build that drew NOTHING across the whole window is exit 1 — the
//     black-screen verdict, the counted check failure the green build catches.
package main

import "../../cli"
import "../../funpack"
import funpack_runtime "../../runtime"
import "core:fmt"
import "core:slice"

// build_render_check_command declares the `render-check` verb node. `--release`
// mirrors build/run (the same hole-ban mode). `--ticks` overrides the cold-start
// window; `--seed` pins the root RNG seed for a `uses_rng` game, exactly as run.
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
			run = cli_render_check_run,
		},
		allocator,
	)
}

// cli_render_check_run adapts the invocation onto run_render_check_verb:
// `--release` maps to the build mode, `--ticks` to the window (the default when
// unset), and `--seed` to the optional root-seed override (nil when unset, so the
// fold resolves the config seed / engine default for a uses_rng game).
cli_render_check_run :: proc(inv: ^cli.Cli_Invocation) -> int {
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

// run_render_check_verb is the `funpack render-check` core: BUILD the project
// tree (the same pure funpack.stage_build the build verb runs), then FOLD the
// built artifact via funpack_runtime.render_check_artifact and render the verdict.
// It mirrors run_run_verb's build half exactly — a build that refuses under
// `funpack build` refuses identically here — and swaps the live-play tail for the
// headless render-reachability fold. root is a parameter (default ".") so the
// build-refusal and no-entrypoint arms are unit-tested against temp trees, the
// run_run_verb testability precedent; main always checks the working dir.
run_render_check_verb :: proc(
	mode: funpack.Build_Mode,
	ticks: int,
	seed_override: Maybe(i64),
	root := ".",
) -> int {
	// BUILD — the same pure seam the build verb compiles, identical refusal block.
	product, verdict := funpack.stage_build(root, mode, context.temp_allocator)
	if verdict.err != .None {
		funpack.eprint_build_refusal("funpack render-check", verdict)
		return 2
	}
	if write_err := funpack.write_build_products(product, root); write_err != .None {
		fmt.eprintfln("funpack render-check: %v", write_err)
		return 2
	}
	// NO ENTRYPOINT — a package (Index Contract only, §30 §7) has no runtime
	// artifact, so there is nothing to render. Refuse before folding.
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
	// A freshly-built artifact that does not re-open is an internal fault (the
	// build wrote it this run), not a user error — exit 2, never the exit-1
	// black-screen verdict, so CI distinguishes "the toolchain broke" from "the
	// game is dark".
	if open_result != .Ok {
		fmt.eprintfln("funpack render-check: could not load the built artifact (%v)", open_result)
		return 2
	}

	// A game with NO `render:` stage (a ui-only or stageless project) draws an
	// empty §20 draw-list BY DESIGN — the UI stage is a separate deferred
	// projection — so an empty window is not a black screen. Report it as not
	// applicable and pass: there is no render stage to assert on.
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

// render_check_frame_label names the first-drawn frame for the OK line: the -1
// post-startup frame reads as "the opening frame", a tick ordinal as "tick N".
// Pure — a function of the ordinal alone.
render_check_frame_label :: proc(frame: int) -> string {
	if frame < 0 {
		return "the opening frame"
	}
	return fmt.tprintf("tick %d", frame)
}
