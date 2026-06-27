package main

import "../../funpack"
import funpack_runtime "../../runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

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

@(test)
test_render_check_drawing_game_reports_drew :: proc(t: ^testing.T) {
	report, ok := rc_build_and_check(t, "funpack-rc-draws", RC_DRAWS_SOURCE)
	if !ok {
		return
	}
	testing.expect(t, report.has_render_stage, "a game with render: has a render stage")
	testing.expect(t, report.drew, "a render behavior emitting a Rect must draw")
	testing.expect(t, report.total_cmds > 0, "the draw-list carries commands")
	testing.expect_value(t, report.first_drawn_frame, -1)
}

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

@(test)
test_render_check_no_render_stage_is_not_applicable :: proc(t: ^testing.T) {
	report, ok := rc_build_and_check(t, "funpack-rc-norender", RC_NO_RENDER_SOURCE)
	if !ok {
		return
	}
	testing.expect(t, !report.has_render_stage, "no render: stage means nothing to assert")
	testing.expect(t, !report.drew, "a stageless render projects an empty draw-list")
}

RC_DRAWING_EXAMPLES :: []string{"snake", "pong", "yard", "krognid", "dungeon", "hunt", "warren"}

RC_NO_RENDER_EXAMPLES :: []string{"hud", "drift", "arena"}

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
		return {}, false
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

@(private = "file")
fmt_rc_temp_name :: proc(name: string) -> string {
	return strings.concatenate({"funpack-rc-example-", name, ".artifact"}, context.temp_allocator)
}

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
