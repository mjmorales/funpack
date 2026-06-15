@doc("The dungeon's thing schema: the types the tilemap's markers and the level's place lines instantiate, plus the loot signal between them. Schema only — no behaviors — so the generated seam can import it without a cycle.")
import engine.math.{Fixed, Vec2}

@doc("A compass heading on the tile grid.")
enum Dir { Up, Down, Left, Right }

@doc("The player avatar, spawned by the grid's named `P` marker. A marker carries no params, so every field beyond the cell-center `pos` defaults. `dir` is the heading the next dig aims at.")
@gtag("actor")
thing Player {
  pos:  Vec2
  dir:  Dir = Dir::Down
  gems: Int = 0
}

@doc("A grid-crawling enemy, spawned per anonymous `g` marker. `rest` counts down to its next one-cell step.")
@gtag("ai")
thing Slime {
  pos:  Vec2
  rest: Fixed = 0.0
}

@doc("A treasure chest. The relational one: placed by name with its bounty set inline at placement.")
@gtag("loot")
thing Chest {
  pos:    Vec2
  gems:   Int = 1
  opened: Bool = false
}

@doc("Emitted the tick a chest opens; the hero folds it into gems.")
@gtag("loot", "event")
signal Looted { gems: Int }
