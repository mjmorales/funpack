package funpack

import "core:testing"

SETUP_VALUES_ENTRYPOINT :: "use mini.{Loop, bindings}\n\nentrypoint main {\n  pipeline = Loop\n  tick = 60hz\n  logical = 160x120\n  bindings = bindings\n}\n"

setup_values_emit :: proc(source: string) -> (artifact: string, err: Emit_Error) {
	identity := Project_Identity{name = "mini", version = "0.1.0"}
	return stage_emit(source, "mini", identity, SETUP_VALUES_ENTRYPOINT, context.temp_allocator)
}

// A setup() that spawns through a multi-statement (`let`-binding) constructor —
// the idiomatic shape a single-`return`-only fold cannot bake — must bake its real
// spawn through the full evaluator, not drop it to an empty [setup] black screen.
@(test)
test_setup_bakes_computed_multistatement_constructor :: proc(t: ^testing.T) {
	source := `import engine.input.{Bindings}
import engine.world.{Spawn}

thing Dot {
  x: Int
  y: Int
}

fn make_dot(n: Int) -> Dot {
  let a = n + 1
  let b = a * 2
  return Dot{x: a, y: b}
}

behavior advance on Dot {
  fn step(self: Dot) -> Dot {
    return self
  }
}

fn bindings() -> Bindings {
  return Bindings.empty()
}

fn setup() -> [Spawn] {
  return [Spawn( make_dot(4) )]
}

pipeline Loop {
  startup: [setup]
  update:  [advance]
}
`
	artifact, err := setup_values_emit(source)
	testing.expect_value(t, err, Emit_Error.None)
	testing.expect(t, artifact_has_line(artifact, "[setup 1]"))
	testing.expect(t, !artifact_has_line(artifact, "[setup 0]"))
	testing.expect(t, artifact_has_line(artifact, "spawn Dot 2"))
	testing.expect(t, artifact_has_line(artifact, "set x =5"))
	testing.expect(t, artifact_has_line(artifact, "set y =10"))
}

// A game that imports the structural stdlib engine.grid.Cell (rather than
// declaring its own `data Cell`) gets a synthesized `data Cell` projection in
// [data], so the runtime types Cell's Int fields and decodes a `Cell(x=N,y=N)`
// token as integers rather than 1/2^32-scaled Fixed bits.
@(test)
test_setup_imported_cell_gets_synthetic_data_decl :: proc(t: ^testing.T) {
	source := `import engine.input.{Bindings}
import engine.world.{Spawn}
import engine.grid.{Cell}

thing Marker {
  at: Cell
}

fn make_marker() -> Marker {
  let c = Cell{x: 3, y: 4}
  return Marker{at: c}
}

behavior advance on Marker {
  fn step(self: Marker) -> Marker {
    return self
  }
}

fn bindings() -> Bindings {
  return Bindings.empty()
}

fn setup() -> [Spawn] {
  return [Spawn( make_marker() )]
}

pipeline Loop {
  startup: [setup]
  update:  [advance]
}
`
	artifact, err := setup_values_emit(source)
	testing.expect_value(t, err, Emit_Error.None)
	testing.expect(t, artifact_has_line(artifact, "data Cell 2 false"))
	testing.expect(t, artifact_has_line(artifact, "field x Int -"))
	testing.expect(t, artifact_has_line(artifact, "field y Int -"))
	testing.expect(t, artifact_has_line(artifact, "set at =Cell(x=3,y=4)"))
}

// A static setup() the evaluator cannot resolve to a closed batch — here a spawn
// through a bare typed hole, which fails closed — refuses the build loudly
// (Setup_Eval_Failed) instead of emitting a silently-empty [setup].
@(test)
test_setup_unevaluable_static_refuses_loudly :: proc(t: ^testing.T) {
	source := `import engine.input.{Bindings}
import engine.world.{Spawn}

thing Dot {
  x: Int
  y: Int
}

fn make_dot() -> Dot @stub(Dot)

behavior advance on Dot {
  fn step(self: Dot) -> Dot {
    return self
  }
}

fn bindings() -> Bindings {
  return Bindings.empty()
}

fn setup() -> [Spawn] {
  return [Spawn( make_dot() )]
}

pipeline Loop {
  startup: [setup]
  update:  [advance]
}
`
	_, err := setup_values_emit(source)
	testing.expect_value(t, err, Emit_Error.Setup_Eval_Failed)
}
