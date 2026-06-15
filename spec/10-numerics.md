# 10 — Numerics: the fixed-point substrate

Every determinism claim rests here: **sim arithmetic is bit-identical on every machine**, including
the transcendentals, which are computed in integer arithmetic so they cannot diverge. `Fixed` is the
one sim number; `Float` exists only behind the visual boundary; `Int` is for counts and indices.

> **Canonical surface.** This component is authoritative for the numeric API: `checked_div`, the
> associated constants, `trunc`/`rsqrt`/`length_sq`/…, and `Quat.axis_angle`/`Quat.mul`.

---

## 1. `Fixed` — one format, no knobs

`Fixed` is a **signed 64-bit Q32.32** (32 integer, 32 fractional bits). The single non-configurable
format — no `Q16.16`-vs-`Q32.32` choice, no per-field precision. Range ≈ ±2.1×10⁹, precision
≈ 2.3×10⁻¹⁰. Multiply uses a 128-bit intermediate shifted back to Q32.32; divide shifts the dividend
up first. Both round **toward zero** — one fixed rounding rule, identical on every machine. The
representation is **transparent integer `data`**, so it serializes, compares (`Eq`/`Ord`), and hashes
like any value — the reason all sim state is `Eq`/`Ord`/`Hash`-safe.

## 2. Total arithmetic — saturate, never wrap, never trap

No panics in sim ([`04`](04-effects.md)), so every operation yields a value, choosing total-and-safe
over total-but-silently-wrong:

- **Overflow saturates** — past `Fixed.MAX` → `Fixed.MAX`; past `Fixed.MIN` → `Fixed.MIN`. Never
  wraps, never traps. **One rule for `Fixed` and `Int` alike.**
- **Division by zero is defined** — `x / 0` saturates by the sign of `x` (`+x → MAX`, `−x → MIN`,
  `0/0 → 0`); `x % 0 → 0`. This keeps `/` and `%` total operators. When detecting a zero divisor *is*
  the point, `checked_div` / `checked_rem` return `Option`, forcing the `match`.
- No wrapping/trapping operators in sim scope (`wrapping_add` is an engine-internal concern).

```funpack
assert Fixed.MAX + 1.0 == Fixed.MAX
assert 1.0 / 0.0 == Fixed.MAX
assert 0.0 / 0.0 == 0.0
assert checked_div(1.0, 0.0) == Option::None
```

## 3. `Int` and `Float`

- **`Int`** — signed 64-bit, **saturating** (counts/indices/scores/ids), same overflow rule. Not a
  sim-position type; mixing into spatial math goes through an **explicit** `to_fixed`, never implicit
  promotion.
- **`Float`** — IEEE-754 binary32, **visual-only**, surfaced by the type and the `f` literal suffix.
  No `Float` appears on any type that flows into a blackboard or signal, so it cannot reach the sim
  by construction; its non-determinism never feeds replay/lockstep.

## 4. Literals are type-directed

| Literal | Type | Where |
|---|---|---|
| `42` | `Int` | anywhere |
| `42.5` | `Fixed` | sim and visual alike — the deterministic default |
| `42.5f` | `Float` | **only** in a visual/render context; a bare `f`-literal in sim code is a compile error |

A `Fixed` literal not exactly representable (`0.1`) is rounded to the nearest `Fixed` at compile
time, deterministically.

## 5. The bit-identical transcendental contract — the heart

> **Every fixed-point transcendental is computed in integer arithmetic** — a polynomial / lookup /
> CORDIC kernel over the `Fixed` representation, with **no float and no libm anywhere in the path**.
> Same input ⇒ same integer operations ⇒ same bits, on every machine, by construction.

These are Tier-1 native `extern`s ([`26`](26-stdlib.md)) carrying the **strongest audit obligation**
in the language; each ships a table of `(input → exact bits)` golden cases, snapshot-tested as a
build gate. This is the trust root the entire determinism thesis stands on. A render behavior may
call float `sin` for cosmetics, but reaching the float path from synced state is a compile error
(the warranty gate, [`25`](25-netcode.md)).

## 6. The scalar surface (`engine.math` over `Fixed`)

| Group | Functions |
|---|---|
| selection | `abs min max clamp sign` |
| rounding | `floor ceil round trunc` → `Int`; `fract` → `Fixed` |
| roots / powers | `sqrt rsqrt`; `pow exp log` |
| trig | `sin cos tan atan2`; `radians degrees`; `wrap_angle` |
| interpolation | `lerp inv_lerp remap` |
| conversion | `to_fixed(Int) -> Fixed`; `floor/ceil/round/trunc(Fixed) -> Int` — explicit, never implicit |

Most are **Tier-2** (ordinary funpack over a tiny Tier-1 core — `lerp` over `+`/`*`, `clamp` over
`min`/`max`); only the irreducible kernels (trig, `sqrt`/`rsqrt`, `exp`/`log`) are native. The caller
cannot tell which tier a function is.

## 7. 3D math

- **Vectors** — `Vec2 { x, y }`, `Vec3 { x, y, z }`: transparent `Fixed` `data` declared
  `data Vec2: Num { … }` / `data Vec3: Num { … }` — the `Num` kind ascribed after the type name.
  The kind confers a **closed operator set** — binary `+`/`-`/`*` (scalar and component-wise per the
  type's shape), unary `-`, and equality — and **nothing more**. It does **not** confer `/`:
  component-wise division, along with `dot cross length length_sq normalize distance reflect`, are
  **named engine functions**, never operators. The `Num` kind is **engine-only**, adorning exactly
  `Vec2`/`Vec3`/`Quat`; a user type never carries it. `normalize` is `v * rsqrt(length_sq(v))`, total
  (a zero vector → zero).
- **Rotation** is a **unit `Quat`**. Drift is controlled mechanically: `Quat.mul` **renormalizes** its
  result via fixed-point `rsqrt`, so a composed orientation is always unit within one `Fixed.EPSILON`.
  `slerp` / `nlerp` are fixed-point natives (`nlerp` the default; `slerp` for constant angular
  velocity). A `Quat` is serializable `data`, so orientation saves/replays/syncs like any state — and
  pose generators are sim-legal ([`16`](16-modeling.md)).
- **Transforms** — `Mat4` (4×4 `Fixed`) composes T/R/S for the render path. `Mat4` is **engine-only
  and not constructible in simulation code** — the sim numeric state is exactly `Fixed`/`Int`/`Vec2`/
  `Vec3`/`Quat`, and matrices live behind the render seam. The engine assembles whatever transforms it
  needs there; sim code never holds a `Mat4`.
- **Angles** are `Fixed` radians, with `pi`/`tau` (nearest-`Fixed`), and `wrap_angle` to keep an
  accumulated angle in `[0, tau)`. Angles are radians, not binary angles — radians is the stronger
  prior, and determinism is already won by the integer kernels.

## 8. Constants & fold order

Constants (fixed engine values, not knobs): `Fixed.MAX` / `Fixed.MIN` / `Fixed.EPSILON`; `pi` /
`tau`; `Vec2.zero` / `Vec3.zero` / `Vec3.up` / …; `Quat.identity`; `Mat4.identity`.

**`fold` is strictly left-to-right.** Fixed-point `+` is **not** reorder-invariant under
saturation/rounding, so a `fold` sum is bit-identical only under a defined order; the engine
guarantees left-to-right, never tree-reduced or parallelized.

```funpack
assert fold([1.0, -1.0], Fixed.MAX, fn(acc, x) { return acc + x }) == Fixed.MAX - 1.0
```
