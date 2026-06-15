@doc("Generated rig seam for Krognid, baked from models/krognid.fpm: the bone skeleton and the part-to-slot mesh bindings the gameplay imports as the krognid module. Edit the .fpm script and re-bake, not this file.")

import engine.anim.{Skeleton, PartSet, Slot, Side}
import engine.assets.mesh

@doc("Bone topology for Krognid: a standard humanoid skeleton. Generated from krognid.fpm — edit the script, not this file. Digest: 16 bones, 6 parts (10 after mirror), pivots verified, rest-bbox 24x20x68.")
@gtag("rig")
fn krognid_skeleton() -> Skeleton {
  return Skeleton.humanoid()
}

@doc("Part meshes bound to bone slots. Left limbs are mirrored to the right at attach time. Generated from krognid.fpm.")
@gtag("rig")
fn krognid_parts() -> PartSet {
  return PartSet.empty()
    .bind(Slot::Torso,     mesh("krognid_torso"))
    .bind(Slot::Head,      mesh("krognid_head"))
    .bind(Slot::LUpperArm, mesh("krognid_upper_arm"))
    .bind(Slot::LLowerArm, mesh("krognid_lower_arm"))
    .bind(Slot::LUpperLeg, mesh("krognid_upper_leg"))
    .bind(Slot::LLowerLeg, mesh("krognid_lower_leg"))
    .mirror(Side::L, Side::R)
}
