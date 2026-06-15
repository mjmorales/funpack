@doc("Generated seam for levels/arena.flvl: typed references to the level's named instances and the deterministic spawn list, baked from the flat-text level. Imports the schema module only. Edit the level, not this file.")
import engine.world.{Spawn, Ref}
import arena_world.{Player, Hunter, Pillar, Switch, Door, Base, Cannon}

@doc("A placed Turret prefab instance: typed references to its expanded members. Generated from the prefab in arena.flvl.")
data ArenaTurret { base: Ref[Base], cannon: Ref[Cannon] }

@doc("Typed references to the Arena level's named instances. Ids are derived from the level-qualified names, so these are stable across loads, saves, and replays. Generated from arena.flvl — edit the level, not this file.")
data Arena {
  hero:      Ref[Player]
  stalker:   Ref[Hunter]
  plate:     Ref[Switch]
  exit:      Ref[Door]
  left_gun:  ArenaTurret
  right_gun: ArenaTurret
}

@doc("The deterministic spawn list for Arena, in declaration order (the prefab and the pillar loop expanded in place). Backed by arena.flvl.")
extern fn arena_spawns() -> [Spawn]

@doc("The Arena symbol table, valid once the level is loaded.")
extern fn arena() -> Arena
