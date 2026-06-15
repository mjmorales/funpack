@doc("Generated seam for levels/dungeon.flvl: the terrain layer's typed TilemapHandle, typed references to the level's named instances, and the deterministic spawn list, baked from the flat-text level. Imports the schema module only. Edit the level, not this file.")
import engine.world.{Spawn, Ref}
import engine.tilemap.{TilemapHandle}
import dungeon_world.{Player, Slime, Chest}

@doc("The terrain layer's typed handle: movement, the dig's SetTile, and the chest's cell test all query the baked layer through it. Generated from the tilemap in dungeon.flvl.")
let terrain: TilemapHandle = TilemapHandle{name: "terrain"}

@doc("Typed references to the Dungeon level's named instances. Ids are derived from the level-qualified names, so these are stable across loads, saves, and replays. Generated from dungeon.flvl — edit the level, not this file.")
data Dungeon {
  hero: Ref[Player]
  loot: Ref[Chest]
}

@doc("The deterministic spawn list for Dungeon: the grid's markers row-major, then the placed chest, in declaration order. Backed by dungeon.flvl.")
extern fn dungeon_spawns() -> [Spawn]

@doc("The Dungeon symbol table, valid once the level is loaded.")
extern fn dungeon() -> Dungeon
