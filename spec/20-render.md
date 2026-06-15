# 20 — The render pipeline

A render behavior is a pure `fn(self) -> [Draw]` (or `[Draw3]`) over **one committed tick** of
fixed-point state — that is what makes it testable by exact equality. Everything a game needs beyond
that (a moving camera, faster-than-tick display, layered draw-lists, post) lives in the **engine**,
operating on the deterministic draw-list the behaviors emit.

> **Thesis:** render behaviors emit a deterministic, fixed-point draw-list of a single committed
> tick; the engine owns camera, frame-rate interpolation, compositing, and post — all visual-only,
> off the determinism path. The draw-list is the assertion ground truth; the pixels are display.

This is the fixed-vs-float boundary drawn at the render seam: the sim produces fixed-point *intent to
draw*; the engine produces float *pixels*.

## 1. Draw commands

**2D** (`engine.render`): `enum Draw { Rect, Line, Text, Fill, Stroke, Sprite, Camera }`.

> `Draw::Camera{ at: Vec2, zoom: Fixed, rotation: Fixed }` (with an optional viewport for
> split-screen) is the 2D twin of `Draw3::Camera`.

`Color` is a closed palette plus `Rgb{ r, g, b }`; `Sprite{ atlas, cell, at, size, tint, flip,
layer }` ([`18`](18-tilemaps.md)); `Fill`/`Stroke` take a `Sketch` ([`16`](16-modeling.md)).

**Anchor (normative):** in every sized draw command (`Rect`, `Sprite`, `Plane`), `at` is the
**center** of the drawn extent, with `size` reaching `size/2` out from it on each axis. A thing's
position is the point its sim logic tests (pong's `overlaps` and `goal_side` read the same `pos`
that `draw_ball` emits), so a draw command anchored at that point renders the entity exactly where
the sim says it is — a corner anchor would shift every visual `size/2` off its collision truth. A
backend projecting to a corner-origin pixel space derives the corner at the present boundary
(`at − size/2`); the command itself never carries a corner. `Text` follows the same rule: `at` is
the **center of the rendered glyph run** (the engine renders block text at fixed metrics), so
`Draw::Text{at: board-center}` reads centered without the author knowing the engine's glyph sizes.

**3D** (`engine.render3`): `enum Draw3 { Mesh{handle, at, material}, Rigged{skeleton, parts, pose,
at}, Plane{at, size, color}, Camera{eye, at, fov}, Light{dir, color} }`. `Material{ color, metallic,
rough }` (helpers `matte`/`pbr`); engine PBR, **no user-authored shaders**.

## 2. Two clocks — tick vs. frame

The sim advances at the fixed `tick`; the display refreshes at the monitor rate. **Render runs once
per tick** (pure, fixed-point, exactly what its unit test asserts). The engine **tweens the draw-list
to the display frame**: it holds the tick-N and tick-N+1 draw-lists (the COW version store retains
recent ticks for free, [`08`](08-state.md)) and emits, each frame, an **interpolated** draw-list at
`alpha = accumulator / tick_dt`.

Correlation is automatic: a command is matched across the two ticks by **the id of the producing
thing** (the engine already iterates in stable id order) plus the command's index. For each matched
pair the engine **lerps continuous fields** (`at`, rotation, scale, `tint`/alpha) and **snaps
discrete ones** (sprite `cell`, `text`, mesh handle, `layer`); a despawn culls at the boundary, a
spawn (or a grown list) appears at the boundary. Interpolation is **float and visual-only**: it is
never recorded, synced, or asserted — the committed tick states are the deterministic truth.

## 3. The camera is state; the view is a command

There is no camera subsystem to configure. The camera is **ordinary sim state** — a `singleton
Camera` (or a `thing`, for split-screen) — driven by **ordinary behaviors**, so follow/deadzone/shake
are pure fixed-point transitions, deterministic and unit-testable. A `view` render behavior emits
`Draw::Camera{ at, zoom, rotation }`; camera-as-data keeps the model uniform and the view interpolates
for free.

- **Logical space, engine letterbox** — the game draws in a fixed logical space (Pong's 160×120); the
  engine scales and letterboxes to the window. Sim coordinates never depend on window size. The
  logical space is **declared** in the entrypoint (`logical = WxH`, [`14`](14-project-config.md) §4)
  — the engine letterboxes to the declared extent, never to a constant inferred from game code.
- **World↔screen is deterministic** (fixed-point camera), and only the engine reads it; it delivers a
  world-space pointer as an input resource ([`23`](23-input.md)) — sim code never sees screen pixels.
- **Multiple camera things → split-screen**, each carrying a viewport rect; the engine renders the
  scene once per camera.

## 4. Compositing & post

All `render:` `[Draw]` lists concatenate in flattened-pipeline order, then the engine orders the
merged list deterministically:

- **2D depth is the explicit `layer: Int`** — a stable sort, ties broken by producing-thing id;
  discrete, so it snaps under interpolation. No implicit list-order depth.
- **3D depth is the camera + z-buffer** (`Draw3::Mesh` depth-tested against the active `Draw3::Camera`).
- **`ui:` composites over `render:` by stage order** ([`21`](21-ui.md)); `audio:` emits no pixels.

**Post-processing** (tonemap, bloom, vignette, grade) is **engine batteries from a closed token set**,
not user shaders — float, visual-only, never sim-readable.

## 5. Determinism

The **draw-list is the deterministic artifact** — a render behavior is a pure fixed-point function of
a committed tick, so its `[Draw]`/`[Draw3]` is bit-identical everywhere and is the assertion ground
truth (`screenshot{include_drawlist}` returns it as data, [`28`](28-introspection.md)). **Pixels are
not deterministic and need not be**: interpolation, letterboxing, rasterization, and post are
float/visual, never recorded, synced, or asserted.

## 6. Scope

The fit policy defaults to letterbox; integer-scale and stretch are presentation config, not a sim
knob. Draw-list correlation is keyed by producing-thing id plus command index (§2).
