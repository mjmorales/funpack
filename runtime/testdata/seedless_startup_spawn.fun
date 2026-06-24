@doc("A minimal seedless game whose startup population is built programmatically (concat over a fold), so the compiler cannot constant-fold it into the [setup] literal batch and emits [setup 0] with the body in [functions] — the colony-sim shape that reproduces friction 116a1681.")

import engine.world.{Spawn}
import engine.list.{fold, concat, len}
import engine.input.Bindings

@doc("A grid-bound mote with an integer cell and hp.")
thing Mote {
  x: Int = 0
  hp: Int = 3
}

@doc("Spawn one mote at column x.")
fn mote_at(x: Int) -> Spawn {
  return Spawn(Mote{x: x, hp: 3})
}

@doc("A list of n placeholder zeros — the deterministic length source the population counts over.")
fn zeros(n: Int) -> [Int] {
  if n <= 0 { return [] }
  return concat([0], zeros(n - 1))
}

@doc("Every column index, built by folding the zeros list into a running count.")
fn cols() -> [Int] {
  return fold(zeros(4), [], fn(acc, _) { return concat(acc, [len(acc)]) })
}

@doc("Spawn a row of motes programmatically — a fold/concat the emitter cannot constant-fold, so it lands in [functions], not the [setup] batch. Seedless: no Rng resource anywhere.")
@gtag("startup")
fn setup() -> [Spawn] {
  return fold(cols(), [], fn(acc, x) { return concat(acc, [mote_at(x)]) })
}

@doc("Advance each mote one cell per tick — a pure self-update, no signals, no Rng.")
@gtag("game")
fn step(self: Mote) -> Mote {
  return Mote{x: self.x + 1, hp: self.hp}
}

@doc("No device input.")
@gtag("input")
fn bindings() -> Bindings {
  return Bindings.empty()
}

@doc("The tick pipeline: spawn the motes at startup, advance them each tick.")
@gtag("game")
pipeline Field {
  startup: [setup]
  move:    [step]
}
