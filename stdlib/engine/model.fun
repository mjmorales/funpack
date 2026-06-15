@doc("The funpack-visible types a .fpm bake emits into a *.gen.fun interface: named anchors, simple sim-side collision shapes, and the baked-geometry handle. The geometry builder vocabulary (box, union, extrude, ...) lives in the bake-time .fpm DSL, not here — see spec/16-modeling.md.")

import engine.prelude.{Fixed, Option}
import engine.math.Vec3
import engine.assets.MeshHandle

@doc("A fixed logical length, the unit of model dimensions. An alias of Fixed for documentation.")
data Length { value: Fixed }

@doc("Named points and sockets on a model, in its local space. Referenced semantically (\"seat_top\") instead of by coordinate (AX8).")
extern type Anchors

@doc("A simple, fixed-point sim-side collision shape. Deterministic; kept far simpler than the render mesh.")
enum Shape3 {
  Box{ size: Vec3 },
  Sphere{ radius: Fixed },
  Capsule{ radius: Fixed, height: Fixed },
  Hull{ points: [Vec3] }
}

@doc("A baked, content-hashed solid. Authored in a .fpm script; opaque in funpack, referenced via its MeshHandle.")
extern type Solid

@doc("An empty anchor set to chain .at / .socket onto. Invoked Anchors.empty().")
extern fn empty() -> Anchors
@doc("Adds a named point anchor in local space.")
extern fn at(self: Anchors, name: String, point: Vec3) -> Anchors
@doc("Adds a named socket (an attach point for other models).")
extern fn socket(self: Anchors, name: String, point: Vec3) -> Anchors
@doc("The local-space position of a named anchor, if it exists.")
extern fn point(self: Anchors, name: String) -> Option[Vec3]

@doc("The render mesh handle for a baked solid.")
extern fn handle(self: Solid) -> MeshHandle
