@doc("A spinning pickup that draws and sounds entirely through generated, typed asset handles from the assets seam.")

import engine.prelude.Fixed
import engine.input.Bindings
import engine.math.{Vec2, tau}
import engine.core.Time
import engine.world.Spawn
import engine.render.{Draw, Color, Flip}
import engine.audio.{Sound, Bus}
import engine.assets.{sound, frame}
import engine.list.is_empty
import assets

@doc("A spinning coin pickup.")
@gtag("actor")
thing Coin { pos: Vec2, spin_t: Fixed = 0.0 }

@doc("A signal: this coin was collected this tick.")
signal Taken {}

@doc("Advances the coin's spin clock, wrapped to one turn.")
@gtag("actor")
behavior advance_spin on Coin {
  fn step(self: Coin, time: Time) -> Coin {
    return self with { spin_t: (self.spin_t + time.dt) % tau }
  }
}

@doc("Draws the coin via the typed atlas constant, animating the spin clip — no asset name appears as a string.")
@gtag("render")
behavior draw_coin on Coin {
  fn step(self: Coin) -> [Draw] {
    return [Draw::Sprite{
      atlas: assets.pickups,
      cell:  assets.pickups.frame("spin", self.spin_t),
      at: self.pos, size: Vec2{x: 8.0, y: 8.0},
      tint: Color::White, flip: Flip::None, layer: 5
    }]
  }
}

@doc("On collection, plays the pickup chime via the typed sound constant.")
@gtag("audio")
behavior on_pickup on Coin {
  fn step(self: Coin, taken: [Taken]) -> (Coin, [Sound]) {
    if is_empty(taken) { return (self, []) }
    return (self, [Sound.sfx(assets.coin_sfx).bus(Bus::Sfx)])
  }
}

@doc("No device-driven input: the pickup spins and sounds on its own clock, so the bindings table is empty.")
@gtag("input")
fn bindings() -> Bindings {
  return Bindings.empty()
}

@doc("Spawns one coin.")
@gtag("startup")
fn setup() -> [Spawn] {
  return [Spawn( Coin{pos: Vec2{x: 80.0, y: 60.0}} )]
}

@doc("A spinning pickup that draws and sounds entirely through generated, typed asset handles.")
@gtag("game")
pipeline Pickups {
  startup: [setup]
  update:  [advance_spin, on_pickup]
  render:  [draw_coin]
}

@doc("The typed handle constant and the manifest-checked string form name the same asset — the constant is just the safe default.")
test "typed constant equals the checked-string handle" {
  assert assets.coin_sfx == sound("coin_sfx")
}
