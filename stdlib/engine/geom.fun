@doc("Vector shapes — the 2D<->3D bridge. A Sketch is a closed/open profile usable two ways: filled or stroked as a 2D Draw, or extruded/revolved into 3D in a .fpm model. One primitive, two consumers, so 2D and 3D never diverge.")

import engine.math.{Vec2, Fixed}

@doc("One step of a vector path. Cubic beziers and arcs cover smooth profiles.")
enum PathOp {
  MoveTo(Vec2),
  LineTo(Vec2),
  CubicTo{ c1: Vec2, c2: Vec2, to: Vec2 },
  Arc{ to: Vec2, radius: Fixed },
  Close
}

@doc("A raw ordered path. Sketch is the friendlier builder over it.")
data Path { ops: [PathOp] }

@doc("A 2D profile built fluently. Filled/stroked in 2D, or extruded/revolved into 3D.")
extern type Sketch

@doc("An axis-aligned rectangle of the given size, centered at the origin.")
extern fn rect(size: Vec2) -> Sketch
@doc("A circle of the given radius, centered at the origin.")
extern fn circle(radius: Fixed) -> Sketch
@doc("A closed polygon through the given points.")
extern fn poly(points: [Vec2]) -> Sketch
@doc("A sketch from an explicit path.")
extern fn from_path(path: Path) -> Sketch

@doc("Rounds the corners of a sketch to a radius.")
extern fn round(self: Sketch, radius: Fixed) -> Sketch
@doc("Translates a sketch.")
extern fn shift(self: Sketch, by: Vec2) -> Sketch
@doc("Rotates a sketch by an angle in radians about the origin.")
extern fn turn(self: Sketch, angle: Fixed) -> Sketch
@doc("Uniformly scales a sketch.")
extern fn scale(self: Sketch, factor: Fixed) -> Sketch
