@doc("Generated typed asset handles, baked from assets.manifest — edit the source, not this file; a rename propagates as a compile error in every reader. Module name is the seam's logical name, assets.")

import engine.assets.{AtlasHandle}
import engine.tilemap.{TilesetHandle}

@doc("The dungeon sprite atlas: the hero, slime, and chest cells the draw behaviors name, plus the terrain tiles' art.")
@gtag("assets")
let dungeon_atlas: AtlasHandle = AtlasHandle{name: "dungeon_atlas"}

@doc("The dungeon tileset: floor, wall, water, and the diggable rubble — each tile's collision verdict is baked into the terrain layer.")
@gtag("assets")
let dungeon: TilesetHandle = TilesetHandle{name: "dungeon"}
