@doc("Generated typed asset handles, baked from assets.manifest — edit the source, not this file; a rename propagates as a compile error in every reader. Module name is the seam's logical name, assets.")

import engine.assets.{AtlasHandle}
import engine.tilemap.{TilesetHandle}

@doc("The warren sprite atlas the maze tiles draw from.")
@gtag("assets")
let warren: AtlasHandle = AtlasHandle{name: "warren"}

@doc("The warren tileset: the maze's floor and solid wall — the two tiles the nav graph derives from.")
@gtag("assets")
let warren_tiles: TilesetHandle = TilesetHandle{name: "warren_tiles"}
