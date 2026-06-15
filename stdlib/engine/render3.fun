@doc("3D draw commands, as data. A render behavior is a pure fn(state) -> [Draw3]; the engine submits the scene. Camera and lights are commands too, so a scene is fully described by returned data. Coordinates here are visual; floats are permitted only in this render context.")

import engine.math.{Vec2, Vec3, Fixed}
import engine.render.Color
import engine.anim.{Skeleton, PartSet, Pose}
import engine.assets.MeshHandle

@doc("A surface appearance. Engine PBR; there are no user-authored shaders (AX2/AX3).")
data Material { color: Color, metallic: Fixed, rough: Fixed }

@doc("A 3D draw command. Returned in a list from a render behavior.")
enum Draw3 {
  @doc("A static mesh placed at a world point with a material.")
  Mesh{ handle: MeshHandle, at: Vec3, material: Material },
  @doc("A posed, part-bound character: the skeleton, its bound parts, the per-frame pose, and a world anchor.")
  Rigged{ skeleton: Skeleton, parts: PartSet, pose: Pose, at: Vec3 },
  @doc("A flat ground/quad of the given XZ extent and color, centered at a point.")
  Plane{ at: Vec3, size: Vec2, color: Color },
  @doc("The view camera: eye position, look-at target, and vertical field of view in degrees.")
  Camera{ eye: Vec3, at: Vec3, fov: Fixed },
  @doc("A directional light: its direction and color.")
  Light{ dir: Vec3, color: Color }
}

@doc("A matte PBR material of a given color: full roughness, no metalness. The common case.")
fn matte(color: Color) -> Material {
  return Material{ color: color, metallic: 0.0, rough: 1.0 }
}

@doc("A PBR material with explicit roughness and metalness.")
fn pbr(color: Color, rough: Fixed, metallic: Fixed) -> Material {
  return Material{ color: color, metallic: metallic, rough: rough }
}
