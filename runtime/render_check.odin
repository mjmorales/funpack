// The "green ≠ works" render-reachability check (decision
// 2026-06-25-single-spawn-things-are-legit-things): a check-clean,
// 100%-test-green funpack build can still ship a black screen, because the unit
// tests fold pure behavior fns in isolation and never exercise the live
// thing → pipeline → render wiring. This check closes that gap with the ONE
// thing a unit test cannot do — it folds the WHOLE pipeline headlessly from a
// cold seeded startup for N ticks and asserts the projected §20 draw-list is
// non-empty on at least one of them. An empty draw-list across the whole window
// is a black screen, caught by the green build instead of by an operator
// staring at a dark SDL window.
//
// It is a pure post-commit projection over a bare Debug_Session (the SAME
// seedless/headless fold a bare `funpack attach` opens, open_session_for_artifact):
// render is a deterministic projection of the committed world (§20 §5), so
// re-projecting each retained version commits nothing and needs no display — the
// check links no SDL and runs inside the define-free test floor. The seed gate is
// program_uses_rng, so a seedless-setup `uses_rng` game is folded SEEDED (the same
// §25 §60 root-seed resolution the live window uses) and its RNG-driven first
// frame populates, rather than freezing at declared defaults and reporting a false
// black screen.
package funpack_runtime

// Render_Check_Report is the verdict of one render-reachability fold: did the
// game draw anything in the first `ticks` of a cold seeded run, and if so at
// which frame. `first_drawn_frame` is the earliest projected frame with a
// non-empty draw-list, numbered like the time cursor (-1 = the post-startup
// initial frame, 0..ticks-1 = the committed result of that tick); it is
// NO_DRAWN_FRAME when the whole window drew nothing. `total_cmds` is the summed
// §20 command count across every projected frame — a coarse "how much was
// drawn" signal for the report, not the pass/fail input (a single command on
// any frame passes). `seeded` records whether the fold ran under a resolved
// root seed (a `uses_rng` game) or seedless.
//
// `has_render_stage` SCOPES the verdict: it is true when the program has a
// `render:` pipeline stage (a 2D [Draw] or 3D [Draw3] projection occupant). The
// black-screen verdict applies ONLY to a game that has one — a game whose only
// terminal projection is `ui:` (the UI stage is a separate, deferred projection)
// or that declares no render stage at all draws an empty §20 draw-list BY
// DESIGN, not by fault, so an empty window there is NOT a black screen. The
// faithful-projection guarantee is what makes the verdict trustworthy: the live
// SDL present path projects through the SAME render_version, so a `drew=false`
// over a render-stage game is exactly the black screen the window would show.
Render_Check_Report :: struct {
	ticks:             int,
	drew:              bool,
	first_drawn_frame: int,
	total_cmds:        int,
	seeded:            bool,
	has_render_stage:  bool,
}

// NO_DRAWN_FRAME is Render_Check_Report.first_drawn_frame when no projected
// frame in the window drew a command — the black-screen verdict. It is distinct
// from the -1 initial-frame ordinal, so a reader never confuses "drew on the
// post-startup frame" with "drew nothing".
NO_DRAWN_FRAME :: -2

// RENDER_CHECK_DEFAULT_TICKS is the cold-start window `funpack render-check`
// folds when no `--ticks` override is given: wide enough that a game whose first
// frame is a brief fade-in or a one-tick spawn delay still draws within it, so
// the verdict flags only a genuine all-window black screen. It matches the bare
// attach window (a render-check sees the same opening run an agent attaching
// would), and is the SANCTIONED escape for a game that legitimately renders
// nothing for its first frames: widen `--ticks` until the real first draw lands
// in range. The fixed default is the determinism-friendly choice — a compiler
// constant, not a per-project dial.
RENDER_CHECK_DEFAULT_TICKS :: ATTACH_FRESH_TICKS

// render_check_session folds the render-reachability verdict over an already-open
// bare session: it projects the post-startup initial frame and each committed
// tick to its §20 draw-list (render_version — the SAME projection observe_draw_list
// dumps) and reports whether any frame drew a command. The initial frame is
// included because a 60hz game's first presented frame is essentially the
// post-startup scene, so a game that draws its opening scene before tick 0 is not
// a black screen. The projection reads the session's recorded empty-input snapshot
// per tick (render is a pure post-commit projection, so the input only feeds a
// render behavior that reads Input — none on the gameplay surface do); a bare
// window's snapshots are all empty(). Non-perturbing: it commits nothing to the
// retained chain.
render_check_session :: proc(s: ^Debug_Session, allocator := context.allocator) -> Render_Check_Report {
	tick_hz := s.program.entrypoint.tick_hz
	report := Render_Check_Report {
		ticks             = len(s.versions),
		first_drawn_frame = NO_DRAWN_FRAME,
		seeded            = s.seed.has_seed,
		has_render_stage  = program_has_render_stage(s.program),
	}

	// The post-startup initial frame (the state tick 0 folds from), projected
	// under empty input — the opening scene the first presented frame shows.
	startup_time := time_resource_at(tick_hz, 0, allocator)
	render_check_accumulate(s, s.startup, empty(), startup_time, -1, &report, allocator)

	// Each committed tick, projected under its recorded (empty) snapshot.
	for version, i in s.versions {
		time := time_resource_at(tick_hz, i, allocator)
		render_check_accumulate(s, version, s.snapshots[i], time, i, &report, allocator)
	}
	return report
}

// program_has_render_stage reports whether the program carries a `render:`
// pipeline stage — the 2D/3D projection slot render_version folds. It scopes the
// black-screen verdict: only a game WITH a render stage is asserted to draw, so a
// ui-only or stageless game (an empty §20 draw-list by design) is never flagged.
// The 3D render3 occupants share the `render` stage name (they emit [Draw3] from
// the same terminal slot), so one stage check covers both.
program_has_render_stage :: proc(program: ^Program) -> bool {
	for step in program.pipeline {
		if step.stage == "render" {
			return true
		}
	}
	return false
}

// render_check_accumulate projects one committed version to its draw-list and
// folds the command count into the running report, recording the first frame
// that drew. Split out so the post-startup frame and every tick fold through the
// identical projection, with one place that decides "drew".
@(private = "file")
render_check_accumulate :: proc(
	s: ^Debug_Session,
	version: World_Version,
	input: Input,
	time: Record_Value,
	frame: int,
	report: ^Render_Check_Report,
	allocator := context.allocator,
) {
	draw := render_version(s.program, version, input, time, allocator)
	if len(draw.cmds) == 0 {
		return
	}
	report.total_cmds += len(draw.cmds)
	if !report.drew {
		report.drew = true
		report.first_drawn_frame = frame
	}
}

// render_check_artifact is the verb-facing core (cli_render_check.odin): open a
// bare seeded session over a built artifact path and fold the render-reachability
// verdict over a `ticks`-wide cold-start window. It threads through the SAME bare
// opener a `funpack attach` uses (open_session_for_artifact), so the fold, the
// `uses_rng` seed resolution, and the empty-input window are identical to the live
// debug surface — the check sees exactly what an agent attaching to the game would.
// A non-`Ok` open (unreadable / malformed artifact) returns a zero report with the
// result code; the caller renders the refusal. The session and its program are
// allocated on `allocator`; a per-call arena reclaims the whole fold.
render_check_artifact :: proc(
	artifact_path: string,
	ticks: int,
	seed_override: Maybe(i64) = nil,
	allocator := context.allocator,
) -> (
	report: Render_Check_Report,
	result: Open_Session_Result,
) {
	session, _, open_result := open_session_for_artifact(
		artifact_path,
		"",
		false,
		allocator,
		seed_override,
		ticks,
	)
	if open_result != .Ok {
		return Render_Check_Report{ticks = ticks, first_drawn_frame = NO_DRAWN_FRAME}, open_result
	}
	return render_check_session(&session, allocator), .Ok
}
