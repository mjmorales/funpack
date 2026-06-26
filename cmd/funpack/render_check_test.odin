// The render-check integration floor: build a §14 tree with funpack.stage_build
// and fold it through funpack_runtime.render_check_artifact — the exact
// compiler → runtime path the `funpack render-check` verb drives — asserting the
// three render-reachability verdicts. This is the "green ≠ works" seam wired into
// the define-free test floor (decision
// 2026-06-25-single-spawn-things-are-legit-things): a regression that stops a
// render-stage game from drawing fails `task test` here, the way a unit test over
// pure behavior fns never could. cmd/funpack is the only package that imports both
// the compiler and the runtime, so this end-to-end build-and-fold lives here; the
// fold is render-pure (no SDL), so it runs under the plain `odin test`.
package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// RC_DRAWS_SOURCE is a minimal game with a render: stage that DRAWS: a single Dot
// spawned at startup, drawn as one Rect every tick. Its render-check verdict is
// drew=true — the positive case the green build pins against a rendering
// regression.
RC_DRAWS_SOURCE :: `import engine.input.{Bindings}
import engine.world.{Spawn}
import engine.render.{Draw, Color}
import engine.math.{Vec2}

fn bindings() -> Bindings { return Bindings.empty() }

thing Dot { pos: Vec2 }

behavior draw_dot on Dot {
  fn step(self: Dot) -> [Draw] {
    return [Draw::Rect{at: self.pos, size: Vec2{x: 8.0, y: 8.0}, color: Color::White}]
  }
}

fn setup() -> [Spawn] {
  return [Spawn( Dot{pos: Vec2{x: 80.0, y: 60.0}} )]
}

pipeline Loop {
  startup: [setup]
  render:  [draw_dot]
}
`

// RC_BLACK_SOURCE is the BLACK-SCREEN case: a render: stage whose behavior
// returns an empty [Draw] list. It is check-clean and would pass a pure-fn test
// suite, yet folds to an empty draw-list — the exact green-but-dark failure the
// render-check exists to catch. Its verdict is has_render_stage=true, drew=false.
RC_BLACK_SOURCE :: `import engine.input.{Bindings}
import engine.world.{Spawn}
import engine.render.{Draw}
import engine.math.{Vec2}

fn bindings() -> Bindings { return Bindings.empty() }

thing Dot { pos: Vec2 }

behavior draw_dot on Dot {
  fn step(self: Dot) -> [Draw] {
    return []
  }
}

fn setup() -> [Spawn] {
  return [Spawn( Dot{pos: Vec2{x: 80.0, y: 60.0}} )]
}

pipeline Loop {
  startup: [setup]
  render:  [draw_dot]
}
`

// RC_NO_RENDER_SOURCE has NO render: stage — only an update behavior. It draws an
// empty §20 draw-list BY DESIGN, so the render-check reports it
// has_render_stage=false (not applicable), never a black screen. This pins the
// scoping that keeps the check from false-failing a ui-only or non-visual project.
RC_NO_RENDER_SOURCE :: `import engine.input.{Bindings}
import engine.world.{Spawn}
import engine.math.{Vec2}

fn bindings() -> Bindings { return Bindings.empty() }

thing Dot { pos: Vec2 }

behavior tick_dot on Dot {
  fn step(self: Dot) -> Dot { return self }
}

fn setup() -> [Spawn] {
  return [Spawn( Dot{pos: Vec2{x: 80.0, y: 60.0}} )]
}

pipeline Loop {
  startup: [setup]
  update:  [tick_dot]
}
`

// rc_build_and_check materializes the source as a §14 tree at a fresh temp root,
// builds it with funpack.stage_build, writes the products, and folds the built
// artifact through render_check_artifact — the verb's exact path. ok=false (the
// caller SKIPs, never false-fails) on a host IO refusal or a build/open fault, so
// a sandboxed FS or an unexpected refusal never red-fails the floor. ticks is the
// cold-start window; 8 is plenty for a one-Dot game whose first frame draws.
@(private = "file")
rc_build_and_check :: proc(
	t: ^testing.T,
	name: string,
	source: string,
) -> (
	report: funpack_runtime.Render_Check_Report,
	ok: bool,
) {
	root, tree_ok := rc_write_tree(name, source)
	if !tree_ok {
		return {}, false
	}
	defer os.remove_all(root)

	product, verdict := funpack.stage_build(root, funpack.Build_Mode.Dev, context.temp_allocator)
	if !testing.expectf(t, verdict.err == .None, "%s must build clean, got %v", name, verdict.err) {
		return {}, false
	}
	if !testing.expect(t, funpack.write_build_products(product, root) == .None, "products must write") {
		return {}, false
	}
	if !testing.expect(t, product.artifact_path != "", "a game tree must produce an artifact") {
		return {}, false
	}

	check, open_result := funpack_runtime.render_check_artifact(
		product.artifact_path,
		8,
		nil,
		context.temp_allocator,
	)
	if !testing.expectf(t, open_result == .Ok, "%s artifact must re-open, got %v", name, open_result) {
		return {}, false
	}
	return check, true
}

// rc_write_tree materializes a minimal valid §14 game tree at a fresh temp root
// carrying `source` as src/mini.fun (the entrypoints.fcfg binds pipeline Loop +
// bindings). ok=false on an IO refusal — the SKIP-on-IO-refusal floor standard.
@(private = "file")
rc_write_tree :: proc(name: string, source: string) -> (root: string, ok: bool) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	root, _ = filepath.join({base, name}, context.temp_allocator)
	os.remove_all(root)
	configs, _ := filepath.join({root, "funpack_configs"}, context.temp_allocator)
	src_dir, _ := filepath.join({root, "src"}, context.temp_allocator)
	if os.make_directory_all(configs) != nil && !os.exists(configs) {
		return "", false
	}
	if os.make_directory_all(src_dir) != nil && !os.exists(src_dir) {
		return "", false
	}
	src_path, _ := filepath.join({src_dir, "mini.fun"}, context.temp_allocator)
	ok_writes :=
		rc_write(configs, "project.fcfg", "project mini {\n  version = \"0.1.0\"\n}\n") &&
		rc_write(configs, "entrypoints.fcfg", "use mini.{Loop, bindings}\n\nentrypoint main {\n  pipeline = Loop\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n") &&
		rc_write(configs, "builds.fcfg", "build native {\n  platform = desktop\n}\n") &&
		rc_write(configs, "tags.fcfg", "tags {\n  game\n}\n") &&
		os.write_entire_file(src_path, transmute([]u8)source) == nil
	if !ok_writes {
		return "", false
	}
	return root, true
}

@(private = "file")
rc_write :: proc(dir: string, name: string, body: string) -> bool {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return os.write_entire_file(path, transmute([]u8)body) == nil
}

// A render: stage that draws is OK: the game has a render stage and drew a
// command on the opening frame.
@(test)
test_render_check_drawing_game_reports_drew :: proc(t: ^testing.T) {
	report, ok := rc_build_and_check(t, "funpack-rc-draws", RC_DRAWS_SOURCE)
	if !ok {
		return
	}
	testing.expect(t, report.has_render_stage, "a game with render: has a render stage")
	testing.expect(t, report.drew, "a render behavior emitting a Rect must draw")
	testing.expect(t, report.total_cmds > 0, "the draw-list carries commands")
	testing.expect_value(t, report.first_drawn_frame, -1) // drew on the opening frame
}

// A render: stage that returns an empty draw-list is a BLACK SCREEN: the green
// build catches it even though the source is check-clean and test-green.
@(test)
test_render_check_empty_render_stage_is_black_screen :: proc(t: ^testing.T) {
	report, ok := rc_build_and_check(t, "funpack-rc-black", RC_BLACK_SOURCE)
	if !ok {
		return
	}
	testing.expect(t, report.has_render_stage, "the game has a render: stage")
	testing.expect(t, !report.drew, "an empty [Draw] return draws nothing — a black screen")
	testing.expect_value(t, report.first_drawn_frame, funpack_runtime.NO_DRAWN_FRAME)
}

// A game with NO render: stage is NOT applicable: an empty draw-list there is by
// design (a ui-only or non-visual project), never flagged as a black screen.
@(test)
test_render_check_no_render_stage_is_not_applicable :: proc(t: ^testing.T) {
	report, ok := rc_build_and_check(t, "funpack-rc-norender", RC_NO_RENDER_SOURCE)
	if !ok {
		return
	}
	testing.expect(t, !report.has_render_stage, "no render: stage means nothing to assert")
	testing.expect(t, !report.drew, "a stageless render projects an empty draw-list")
}

// RC_DRAWING_EXAMPLES are the shipped example games that MUST draw something on a
// cold seeded start: the corpus regression gate. If a future change breaks the
// live thing → pipeline → render wiring of any of them, this fails the green build
// — the regression protection a per-behavior test cannot give. Most draw through a
// render: stage; warren draws its baked tilemap terrain (a Draw_Tilemap, no render
// behavior), so the gate asserts only that each DREW, not how. examples/assets is
// excluded: it has a render: stage whose Draw::Sprite folds to an empty draw-list
// (a runtime sprite-render gap), so it would fail this gate — add it to this list
// when it draws.
RC_DRAWING_EXAMPLES :: []string{"snake", "pong", "yard", "krognid", "dungeon", "hunt", "warren"}

// RC_NO_RENDER_EXAMPLES are shipped examples with no render: stage — a ui-only
// (hud), empty-pipeline (drift), or AI-only (arena) project. They pin the scoping
// over real games: an empty draw-list there is not-applicable, never a black
// screen.
RC_NO_RENDER_EXAMPLES :: []string{"hud", "drift", "arena"}

// rc_check_example builds a shipped example READ-ONLY (stage_build writes nothing;
// the product's artifact bytes go to a temp file, so the example tree's .funpack/
// is never touched) and folds it through render_check_artifact. ok=false (the
// caller SKIPs, never false-fails) when the example checkout is absent — the
// golden-skip standard — or on a host IO/build refusal.
@(private = "file")
rc_check_example :: proc(
	t: ^testing.T,
	name: string,
) -> (
	report: funpack_runtime.Render_Check_Report,
	ok: bool,
) {
	dir, _ := filepath.join({"..", "..", "examples", name}, context.temp_allocator)
	if !os.exists(dir) {
		return {}, false // absent checkout — skip, never fail
	}
	product, verdict := funpack.stage_build(dir, funpack.Build_Mode.Dev, context.temp_allocator)
	if !testing.expectf(t, verdict.err == .None, "example %s must build clean, got %v", name, verdict.err) {
		return {}, false
	}
	if !testing.expectf(t, product.artifact_path != "", "example %s must produce an artifact", name) {
		return {}, false
	}
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {
		base = "/tmp"
	}
	art, _ := filepath.join({base, fmt_rc_temp_name(name)}, context.temp_allocator)
	if os.write_entire_file(art, transmute([]u8)product.artifact) != nil {
		return {}, false
	}
	defer os.remove(art)
	check, open_result := funpack_runtime.render_check_artifact(art, 8, nil, context.temp_allocator)
	if !testing.expectf(t, open_result == .Ok, "example %s artifact must re-open, got %v", name, open_result) {
		return {}, false
	}
	return check, true
}

// fmt_rc_temp_name names the per-example temp artifact, distinct per example so a
// parallel test run never collides on the file.
@(private = "file")
fmt_rc_temp_name :: proc(name: string) -> string {
	return strings.concatenate({"funpack-rc-example-", name, ".artifact"}, context.temp_allocator)
}

// Every shipped game with a render: stage draws on a cold seeded start — the green
// build's regression gate against a black-screen regression in a real example.
@(test)
test_render_check_drawing_examples_draw :: proc(t: ^testing.T) {
	for name in RC_DRAWING_EXAMPLES {
		report, ok := rc_check_example(t, name)
		if !ok {
			continue
		}
		testing.expectf(t, report.drew, "%s must draw from a cold seeded start (a black screen otherwise)", name)
	}
}

// Every shipped game without a render: stage is not-applicable — the scoping holds
// over real ui-only / non-visual games, never flagged as a black screen.
@(test)
test_render_check_no_render_examples_are_not_applicable :: proc(t: ^testing.T) {
	for name in RC_NO_RENDER_EXAMPLES {
		report, ok := rc_check_example(t, name)
		if !ok {
			continue
		}
		testing.expectf(t, !report.has_render_stage, "%s declares no render: stage", name)
	}
}
