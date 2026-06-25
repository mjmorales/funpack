@doc("A uses_rng game whose setup is seedless but whose per-tick behavior draws from the engine Rng. The setup binds no Rng, so the run is not setup-seeded; the seed_draw behavior binds Rng, so the program draws randomness anyway. The engine supplies and records a run-scoped root seed because the program draws, threads it per tick, and the spawning behavior folds — the seedless-setup, per-tick-RNG shape that requires the root-seed contract.")
import engine.world.{Spawn}
import engine.input.{Bindings}
import engine.rand.{Rng, range}

@doc("The single instance the per-tick draw folds over. It exists to host the seed_draw behavior.")
thing Spawner {
  ticks: Int = 0
}

@doc("One drawn dot. Its cell is the integer the threaded Rng drew on the tick that spawned it, so the committed set of cells is a function of the root seed.")
thing Mote {
  cell: Int = 0
}

@doc("Seedless startup: spawns the single Spawner the per-tick draw folds over. Binds no Rng, so the run is not setup-seeded.")
@gtag("startup")
fn setup() -> [Spawn] {
  return [Spawn( Spawner{} )]
}

@doc("Each tick draws a cell in [0, 10) from the threaded Rng and spawns a Mote there, threading the advanced Rng forward. Binds Rng, so the program draws randomness even though setup does not.")
@gtag("rng")
behavior seed_draw on Spawner {
  fn step(self: Spawner, rng: Rng) -> (Rng, [Spawn]) {
    let (cell, next) = rng.range(0, 10)
    return (next, [Spawn( Mote{cell: cell} )])
  }
}

@doc("No input is bound: the game advances purely from the threaded Rng each tick.")
fn bindings() -> Bindings {
  return Bindings.empty()
}

@doc("A seedless-setup, per-tick-RNG pipeline at a fixed 8hz: setup spawns the Spawner, then seed_draw draws and spawns one Mote each tick.")
@gtag("game")
pipeline Seedfix {
  startup: [setup]
  step:    [seed_draw]
}
