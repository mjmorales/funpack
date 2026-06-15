@doc("The warren's thing schema: the chase cast — a ferret hunting a rabbit through a baked maze — and the burrow goals the rabbit runs for. Schema only — no behaviors — so the generated level seam can import it without a cycle.")
import engine.math.{Fixed, Vec2}
import engine.nav.Path

@doc("The hunted rabbit. `path` caches its current escape route; `hidden` flips when it reaches a burrow mouth and leaves the chase.")
@gtag("ai")
thing Rabbit {
  pos:    Vec2
  path:   Path = Path{steps: [], cost: 0.0}
  hidden: Bool = false
}

@doc("The hunting ferret. `path` holds the last good route so a failed query never strands it; `repath_t` is the Fixed re-path countdown — the ferret re-queries on its own clock, never on an engine cadence.")
@gtag("ai")
thing Ferret {
  pos:      Vec2
  path:     Path = Path{steps: [], cost: 0.0}
  repath_t: Fixed = 0.0
}

@doc("A burrow mouth the rabbit can vanish into. Placed by the level; the sealed one is walled off, so reachability — not existence — decides whether it is a real goal.")
@gtag("scenery")
thing Burrow {
  pos: Vec2
}
