@doc("2D draw commands, as data. A render behavior is a pure fn(state) -> [Draw]; the engine rasterizes the list. Owns Color, shared with 3D.")

import engine.prelude.Int
import engine.math.{Vec2, Fixed}
import engine.geom.Sketch
import engine.assets.AtlasHandle

@doc("Sprite mirroring: reuse one set of cells for both facings.")
enum Flip { None, X, Y, XY }

@doc("A color. Named palette entries cover the common cases; Rgb is the escape to an exact value (0..1 channels).")
enum Color {
  White, Black, Red, Green, Blue, Yellow, Cyan, Magenta, Gray,
  Rgb{ r: Fixed, g: Fixed, b: Fixed }
}

@doc("Horizontal text alignment.")
enum Align { Left, Center, Right }

@doc("A loaded font face. Engine-provided.")
extern type Font

@doc("A 2D draw command. Returned in a list from a render behavior.")
enum Draw {
  @doc("A filled axis-aligned rectangle at a top-left point.")
  Rect{ at: Vec2, size: Vec2, color: Color },
  @doc("A line segment between two points.")
  Line{ a: Vec2, b: Vec2, color: Color },
  @doc("A run of text anchored at a point.")
  Text{ at: Vec2, text: String, color: Color },
  @doc("A filled vector path (the 2D side of the geometry bridge).")
  Fill{ path: Sketch, color: Color },
  @doc("A stroked vector path of a given width.")
  Stroke{ path: Sketch, width: Fixed, color: Color },
  @doc("A textured quad: a named cell of an atlas, tinted, flipped, and z-sorted by layer.")
  Sprite{ atlas: AtlasHandle, cell: String, at: Vec2, size: Vec2, tint: Color, flip: Flip, layer: Int }
}
