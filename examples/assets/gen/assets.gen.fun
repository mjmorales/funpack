@doc("Generated typed asset handles, baked from assets.manifest — edit the source, not this file; a rename propagates as a compile error in every reader. Module name is the seam's logical name, assets.")

import engine.assets.{MeshHandle, AtlasHandle, SoundHandle}

@doc("The coin model's mesh. Generated from the manifest — edit the source, not this file; a rename propagates as a compile error in every reader.")
@gtag("assets")
let coin: MeshHandle = MeshHandle{name: "coin"}

@doc("The pickups sprite atlas (cells coin/gem/key, clip spin).")
@gtag("assets")
let pickups: AtlasHandle = AtlasHandle{name: "pickups"}

@doc("The coin pickup chime.")
@gtag("assets")
let coin_sfx: SoundHandle = SoundHandle{name: "coin_sfx"}
