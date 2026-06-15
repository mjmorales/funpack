@doc("The arena's thing schema: the placeable types (player, hunter, cover, switch-gated door, turret parts) the level instantiates and the behavior module animates. Schema only — no behaviors — so the generated seam can import it without a cycle.")
import engine.math.{Fixed, Vec2}
import engine.nav.Path
import engine.world.Ref

@doc("The player avatar. `pos` is the conventional position field the level's `at` sets.")
@gtag("actor")
thing Player { pos: Vec2 }

@doc("An enemy that paths to the player across the arena. `path` caches the last route so it keeps moving when a query fails.")
@gtag("ai")
thing Hunter { pos: Vec2, path: Path = Path{ steps: [], cost: 0.0 } }

@doc("A piece of static cover.")
@gtag("scenery")
thing Pillar { pos: Vec2 }

@doc("A floor switch. Flips on while stepped on; here it just holds its state.")
@gtag("mechanism")
thing Switch { pos: Vec2, on: Bool = false }

@doc("A gate that opens while its bound switch is on. `gate` is a typed reference set at placement.")
@gtag("mechanism")
thing Door { pos: Vec2, gate: Ref[Switch], open: Bool = false }

@doc("A turret base.")
@gtag("turret")
thing Base { pos: Vec2 }

@doc("A turret cannon, with a fire rate.")
@gtag("turret")
thing Cannon { pos: Vec2, rate: Fixed }
