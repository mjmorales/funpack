@doc("Skeletons, parts, and poses. A pose is plain value data and a pose generator is a pure fn(state) -> Pose, so animation is the functional core applied to bones: composable with two primitives, deterministic, unit-testable. Poses over fixed-point math are sim-legal and replay-safe.")

import engine.prelude.{Fixed, Bool}
import engine.math.{Vec3, Quat}
import engine.assets.MeshHandle

@doc("A named bone. 16 humanoid bones plus generic robot joints; absent bones default to rest.")
enum Bone {
  Hips, Torso, Neck, Head,
  LUpperArm, LLowerArm, LHand, RUpperArm, RLowerArm, RHand,
  LUpperLeg, LLowerLeg, LFoot, RUpperLeg, RLowerLeg, RFoot,
  Joint0, Joint1, Joint2, Joint3, Joint4, Joint5, Joint6, Joint7
}

@doc("A part attachment point, mapped to a bone by the skeleton's slot map.")
enum Slot {
  Torso, Head,
  LUpperArm, LLowerArm, LHand, RUpperArm, RLowerArm, RHand,
  LUpperLeg, LLowerLeg, LFoot, RUpperLeg, RLowerLeg, RFoot,
  Slot0, Slot1, Slot2, Slot3
}

@doc("Body side, for mirroring left-authored parts to the right.")
enum Side { L, R }

@doc("A local bone transform: translation, orientation, and scale relative to the parent bone.")
data Transform { pos: Vec3, rot: Quat, scale: Vec3 }

@doc("A bone hierarchy: an ordered bone list, parent links, rest transforms, and the part-slot map. Built by a factory or generated from a .fpm rig.")
extern type Skeleton

@doc("A sparse map of bone -> local transform. Bones it omits sit at rest. Immutable value.")
extern type Pose

@doc("Part meshes bound to bone slots, with optional left->right mirroring at attach time.")
extern type PartSet

@doc("The identity transform: no translation, no rotation, unit scale.")
extern fn identity() -> Transform
@doc("A transform that rotates angle radians about the local X axis (pitch).")
extern fn rot_x(angle: Fixed) -> Transform
@doc("A transform that rotates angle radians about the local Y axis (yaw).")
extern fn rot_y(angle: Fixed) -> Transform
@doc("A transform that rotates angle radians about the local Z axis (roll).")
extern fn rot_z(angle: Fixed) -> Transform
@doc("A transform that translates by d along the local +Y (up) axis.")
extern fn up(d: Fixed) -> Transform
@doc("A transform that translates by an explicit offset.")
extern fn translate(offset: Vec3) -> Transform

@doc("The standard 16-bone humanoid skeleton.")
extern fn humanoid() -> Skeleton
@doc("A four-legged skeleton.")
extern fn quadruped() -> Skeleton
@doc("A basic jointed robot skeleton.")
extern fn robot() -> Skeleton

@doc("An empty pose: every bone at rest. Chain .set to drive specific bones. Invoked Pose.empty().")
extern fn empty() -> Pose
@doc("Sets one bone's local transform, returning the updated pose.")
extern fn set(self: Pose, bone: Bone, transform: Transform) -> Pose
@doc("The transform a pose assigns to a bone, or the identity if it drives none.")
extern fn get(self: Pose, bone: Bone) -> Transform
@doc("Whether a pose drives a given bone.")
extern fn has(self: Pose, bone: Bone) -> Bool

@doc("Per-bone weighted interpolation (lerp position, slerp rotation) from a to b. For state transitions.")
extern fn blend(a: Pose, b: Pose, weight: Fixed) -> Pose
@doc("Channel composition: overlay's bones replace base's; base shows through elsewhere. Layer order is the override order.")
extern fn layer(base: Pose, overlay: Pose) -> Pose

@doc("An empty part set to chain .bind / .mirror onto. Invoked PartSet.empty().")
extern fn empty() -> PartSet
@doc("Binds a mesh to a bone slot.")
extern fn bind(self: PartSet, slot: Slot, handle: MeshHandle) -> PartSet
@doc("Mirrors every part bound on one side onto the other at attach time.")
extern fn mirror(self: PartSet, from: Side, to: Side) -> PartSet
