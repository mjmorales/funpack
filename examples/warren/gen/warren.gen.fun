@doc("Generated seam for levels/warren.flvl: the maze layer's typed TilemapHandle, typed references to the level's four named animals and burrows, and the deterministic spawn list, baked from the flat-text level. Imports the schema module only. Edit the level, not this file.")
import engine.world.{Spawn, Ref}
import engine.tilemap.{TilemapHandle}
import warren_world.{Rabbit, Ferret, Burrow}

@doc("The maze layer's typed handle. The nav graph derives from exactly this layer's solids, so the picture is the topology. Generated from the tilemap in warren.flvl.")
let maze: TilemapHandle = TilemapHandle{name: "maze"}

@doc("Typed references to the Warren level's named instances, in row-major marker order. Ids are derived from the level-qualified names, so these are stable across loads, saves, and replays. Generated from warren.flvl — edit the level, not this file.")
data Warren {
  doe:    Ref[Rabbit]
  den:    Ref[Burrow]
  sealed: Ref[Burrow]
  hob:    Ref[Ferret]
}

@doc("The deterministic spawn list for Warren: the maze's named markers, row-major. Backed by warren.flvl.")
extern fn warren_spawns() -> [Spawn]

@doc("The Warren symbol table, valid once the level is loaded.")
extern fn warren() -> Warren
