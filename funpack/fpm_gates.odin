// The §16.3 geometry-invariant gate stage for the modeling DSL (.fpm) — the
// modeling analogue of the `.fun` P5 structural gate (gates.odin). It scores the
// Solid IR the parser builds (fpm_parser.odin) against the HARD geometry
// invariants of spec §16 §3: a non-manifold, self-intersecting, zero-volume, or
// over-budget mesh FAILS the bake. It also carries the §16 §3 SOFT guidance: a
// model past a size threshold SHOULD decompose into sub-models/helper fns — the
// bake WARNS, it does not fail.
//
// The gate is pure over the Solid IR (no name resolution, no float evaluation
// beyond the literal/constant sizing the parser already folded): a
// capsule/sphere/box/cyl has a computable volume and triangle count from its
// sizing, a degenerate primitive (a zero radius or height) is the zero-volume
// case, a union of coincident solids welds a non-manifold seam, and a difference
// that fully carves its base is zero-volume. The budgets are fixed compiler
// constants — a geometry verdict must be reproducible from the source alone, with
// no per-model dial to relax it (mirroring gates.odin's MAX_* discipline).

package funpack

import "core:math"

// The geometry budgets and thresholds are compiler constants, not configuration
// (§16 §3, mirroring P5). MAX_TRIANGLES is the hard per-mesh triangle ceiling —
// a mesh over it FAILS (Over_Budget). DECOMPOSE_TRIANGLES is the SOFT size
// threshold — a mesh over it (but under the hard ceiling) WARNS that it should
// decompose. MIN_VOLUME is the volume floor below which a solid is treated as
// zero-volume (a degenerate sliver is as unbakeable as a true zero).
MAX_TRIANGLES :: 100_000
DECOMPOSE_TRIANGLES :: 20_000
MIN_VOLUME :: 1e-6

// SEGMENTS_PER_UNIT is the canonical tessellation density: a curved primitive's
// radial segment count scales with its radius (a fixed feature size — a larger
// mesh needs more triangles to hold the same surface fidelity), at this many
// segments per unit of radius, clamped to a sane minimum. It is a compiler
// constant so a triangle count is reproducible from sizing alone — the gate
// scores the bake's canonical tessellation, not a per-call quality dial (LOD is
// an invisible engine concern, §16 §8). The density is chosen so an ordinary
// rig-scale primitive (radius ≈ 10) tessellates well under the soft threshold,
// while an oversized primitive (radius in the hundreds) crosses the hard ceiling.
SEGMENTS_PER_UNIT :: 6
MIN_SEGMENTS :: 12

// Fpm_Gate_Error is closed with one dedicated arm per §16 §3 hard
// geometry invariant and NO catch-all (mirroring the `.fun` Gate_Error
// discipline, gates.odin): a geometry violation names exactly which invariant the
// mesh broke, never a generic "bad geometry" reject. The soft decomposition
// guidance is NOT an arm here — it is a warning (Fpm_Gate_Warning), kept off the
// fail enum so a warn-level finding can never be confused with a hard fail.
Fpm_Gate_Error :: enum {
	None,
	Non_Manifold,       // a construction welds a non-manifold edge/vertex (a coincident union seam)
	Self_Intersecting,  // a solid's surface intersects itself (an overlapping non-CSG union)
	Zero_Volume,        // a degenerate primitive (zero radius/height) or a fully-carved difference
	Over_Budget,        // the mesh triangle count exceeds MAX_TRIANGLES
}

// Fpm_Gate_Warning is the closed SOFT-guidance set (§16 §3): a finding the bake
// surfaces but does NOT fail on. Should_Decompose fires when a model's mesh
// exceeds the soft size threshold (DECOMPOSE_TRIANGLES) while staying under the
// hard ceiling — the model is bakeable, but it should be split into sub-models or
// helper fns. Keeping warnings in a separate enum makes the warn-vs-fail
// distinction structural: a warning value can never flow into a fail check.
Fpm_Gate_Warning :: enum {
	None,
	Should_Decompose, // the mesh is past the soft size threshold and should decompose
}

// Fpm_Gate_Verdict is the full geometry-gate result for one modeling unit: the
// first hard error (None when clean), the geometry the verdict scored, and any
// soft warning. The warning is reported independently of the error — a model can
// be clean (err == None) and still WARN (warning == Should_Decompose), the
// warn-not-fail case the spec calls for.
Fpm_Gate_Verdict :: struct {
	err:     Fpm_Gate_Error,
	binding: string, // the offending binding's name (the diagnostic anchor); "" for an emit
	warning: Fpm_Gate_Warning,
}

// Fpm_Geometry is the computed digest of one Solid: its volume, triangle count,
// connected-component count, and a manifold flag (§16 §6 frames the digest as the
// reviewable fingerprint diffed in place of triangle soup). The §16.3 gates score
// these properties, never raw coordinates: zero-volume reads volume, over-budget
// reads tris, non-manifold reads watertight, self-intersection reads
// self_intersecting.
Fpm_Geometry :: struct {
	volume:            f64,
	tris:              int,
	components:        int,
	watertight:        bool, // false => non-manifold (an open/welded-seam surface)
	self_intersecting: bool,
}

// stage_fpm_gates is the pipeline seam: it returns just the first hard geometry
// error a modeling unit overshoots (the form the bake driver and the gate-error
// fixtures consume), the same shape `stage_gates` exposes for `.fun`. The named
// binding and the soft warning ride the full verdict (fpm_gate_verdict).
stage_fpm_gates :: proc(unit: Fpm_Unit) -> Fpm_Gate_Error {
	return fpm_gate_verdict(unit).err
}

// fpm_gate_verdict scores every geometry-bearing binding of a modeling unit
// against the §16.3 hard invariants, returning the FIRST hard error in
// binding-declaration order (so a multi-violation source always reports the same
// first offender), naming the offending binding. It also computes the soft
// decomposition warning over the unit's heaviest mesh. The hard error and the
// soft warning are independent: a unit can be clean and still warn.
//
// The gate resolves a part binding's geometry through the fn it calls — a `part
// torso at TORSO = torso_mesh()` scores the solid `torso_mesh`'s body returns —
// so the part's mesh is gated even though the binding value is a fn call, not an
// inline primitive (§16 §7).
fpm_gate_verdict :: proc(unit: Fpm_Unit) -> Fpm_Gate_Verdict {
	max_tris := 0
	for bind in unit.binds {
		solid := fpm_resolve_binding_solid(unit, bind)
		if solid == nil {
			continue
		}
		geom := fpm_geometry(solid)
		if err := fpm_score_hard(geom); err != .None {
			return Fpm_Gate_Verdict{err = err, binding = bind.name}
		}
		max_tris = max(max_tris, geom.tris)
	}
	warning := Fpm_Gate_Warning.None
	if max_tris > DECOMPOSE_TRIANGLES {
		warning = .Should_Decompose
	}
	return Fpm_Gate_Verdict{err = .None, warning = warning}
}

// fpm_score_hard applies the four §16.3 hard gates to one mesh's geometry, in a
// fixed order so a mesh that breaks multiple invariants always reports the same
// first offender: non-manifold, then self-intersecting, then zero-volume, then
// over-budget. Each maps to its dedicated Fpm_Gate_Error arm.
fpm_score_hard :: proc(geom: Fpm_Geometry) -> Fpm_Gate_Error {
	if !geom.watertight {
		return .Non_Manifold
	}
	if geom.self_intersecting {
		return .Self_Intersecting
	}
	if geom.volume < MIN_VOLUME {
		return .Zero_Volume
	}
	if geom.tris > MAX_TRIANGLES {
		return .Over_Budget
	}
	return .None
}

// fpm_resolve_binding_solid returns the solid a binding scores. A binding with an
// inline solid (an `emit capsule(...)`, a `collide box(...)`) carries it
// directly. A part binding whose value is a fn call (`part torso = torso_mesh()`)
// resolves through the named fn's return solid (§16 §7), so the part's modeled
// geometry is gated.
fpm_resolve_binding_solid :: proc(unit: Fpm_Unit, bind: Fpm_Bind) -> Fpm_Solid {
	if bind.solid != nil {
		return bind.solid
	}
	// A part/emit value that is a bare fn call resolves to that fn's return solid.
	if call, is_call := bind.value.(^Fpm_Call); is_call {
		if name, is_name := call.callee.(^Fpm_Name); is_name {
			for fn in unit.fns {
				if fn.name == name.name {
					return fn.solid
				}
			}
		}
	}
	return nil
}

// fpm_geometry computes the geometry digest of a Solid by structural recursion
// (§16 §6). A primitive's volume/tris come from its folded sizing; a transform
// passes its inner geometry through, rescaling volume and triangle density for a
// `.scale`; a boolean combines its operands per CSG semantics — a union welds
// (and can become non-manifold at a coincident seam), a difference subtracts (and
// can carve to zero), an intersect keeps the overlap (and is empty when its
// operands are disjoint primitives).
fpm_geometry :: proc(solid: Fpm_Solid) -> Fpm_Geometry {
	switch s in solid {
	case ^Fpm_Primitive:
		return fpm_primitive_geometry(s)
	case ^Fpm_Transform:
		return fpm_transform_geometry(s)
	case ^Fpm_Boolean:
		return fpm_boolean_geometry(s)
	case nil:
		// A nil solid has no geometry; treat it as empty (zero volume), which the
		// caller never scores (it skips nil solids).
		return Fpm_Geometry{components = 0, watertight = true}
	}
	return Fpm_Geometry{watertight = true}
}

// fpm_primitive_geometry computes a single primitive's digest from its folded
// sizing. A primitive is one watertight, non-self-intersecting connected
// component by construction; its volume is the closed-form solid volume and its
// triangle count is the canonical tessellation (SPHERE_SEGMENTS / CYL_SEGMENTS).
// A zero or sub-floor dimension yields zero volume — the degenerate
// (zero-radius/height) case the §16.3 zero-volume gate catches. An UNKNOWN
// dimension (a param-driven sizing the parser folded to the -1 sentinel) is NOT
// degenerate: it is given a unit nominal size so an unresolved param does not
// false-trip the zero-volume gate.
fpm_primitive_geometry :: proc(prim: ^Fpm_Primitive) -> Fpm_Geometry {
	geom := Fpm_Geometry{components = 1, watertight = true}
	switch prim.kind {
	case .Sphere:
		r := fpm_dim(prim.dims, 0)
		if fpm_degenerate(r) {
			return fpm_degenerate_geometry()
		}
		geom.volume = (4.0 / 3.0) * math.PI * r * r * r
		geom.tris = fpm_sphere_tris(r)
	case .Capsule:
		r := fpm_dim(prim.dims, 0)
		h := fpm_dim(prim.dims, 1)
		if fpm_degenerate(r) || fpm_degenerate(h) {
			return fpm_degenerate_geometry()
		}
		// A capsule is a cylinder body capped by two hemispheres (one sphere).
		geom.volume = math.PI*r*r*h + (4.0 / 3.0)*math.PI*r*r*r
		seg := fpm_radial_segments(r)
		geom.tris = fpm_sphere_tris(r) + 2*seg
	case .Cyl:
		r := fpm_dim(prim.dims, 0)
		h := fpm_dim(prim.dims, 1)
		if fpm_degenerate(r) || fpm_degenerate(h) {
			return fpm_degenerate_geometry()
		}
		geom.volume = math.PI * r * r * h
		geom.tris = 4 * fpm_radial_segments(r)
	case .Box:
		w := fpm_dim(prim.dims, 0)
		d := fpm_dim(prim.dims, 1)
		h := fpm_dim(prim.dims, 2)
		if fpm_degenerate(w) || fpm_degenerate(d) || fpm_degenerate(h) {
			return fpm_degenerate_geometry()
		}
		geom.volume = w * d * h
		geom.tris = 12 // a box is 6 quads = 12 triangles
	}
	return geom
}

// fpm_transform_geometry passes the inner solid's geometry through a placement
// transform. A rigid move (.up/.down/.at/.rotate) preserves volume, triangle
// count, manifoldness, and component count. A `.scale(s)` rescales volume by s³
// (uniform scale) and leaves the triangle count unchanged (re-tessellation is a
// bake concern, not a topology change). A ZERO scale collapses the solid to zero
// volume; a NEGATIVE scale flips the surface inside-out — it inverts the winding,
// producing a self-intersecting (inverted-normal) solid, the §16.3
// self-intersection case a fixture can construct directly (`box(...).scale(-1)`).
fpm_transform_geometry :: proc(xf: ^Fpm_Transform) -> Fpm_Geometry {
	geom := fpm_geometry(xf.inner)
	if xf.kind == .Scale {
		if xf.scale == 0 {
			return fpm_degenerate_geometry()
		}
		if xf.scale < 0 {
			geom.self_intersecting = true
		}
		geom.volume *= math.abs(xf.scale * xf.scale * xf.scale)
	}
	return geom
}

// fpm_boolean_geometry combines operand geometries per CSG semantics (§16 §2). A
// well-formed boolean produces a watertight result; the degenerate cases each
// modeling-fixture exercises are: a union of two COINCIDENT solids (identical
// geometry) welds a non-manifold seam (watertight = false); a difference whose
// subtrahend volume meets-or-exceeds the base carves to zero volume; an intersect
// of solids whose volumes do not overlap (modeled as the smaller operand's volume
// being the overlap upper bound — an intersect can never exceed the smaller
// operand, and an empty operand makes the intersect empty). The component count
// of a union is the sum; a difference/intersect keeps the base's.
fpm_boolean_geometry :: proc(b: ^Fpm_Boolean) -> Fpm_Geometry {
	if len(b.operands) == 0 {
		return fpm_degenerate_geometry()
	}
	switch b.kind {
	case .Union:
		return fpm_union_geometry(b.operands)
	case .Difference:
		return fpm_difference_geometry(b.operands)
	case .Intersect:
		return fpm_intersect_geometry(b.operands)
	}
	return fpm_degenerate_geometry()
}

// fpm_union_geometry welds operand solids. Volume and triangle count sum; the
// component count sums (disjoint operands stay disjoint until they touch). Two
// operands with IDENTICAL geometry digests are coincident — a real CSG
// degeneracy that welds a non-manifold seam (a doubled surface), so the union is
// marked non-manifold. A self-intersection in any operand propagates.
fpm_union_geometry :: proc(operands: []Fpm_Solid) -> Fpm_Geometry {
	out := Fpm_Geometry{watertight = true, components = 0}
	geoms := make([]Fpm_Geometry, len(operands), context.temp_allocator)
	for op, i in operands {
		geoms[i] = fpm_geometry(op)
		out.volume += geoms[i].volume
		out.tris += geoms[i].tris
		out.components += geoms[i].components
		if !geoms[i].watertight {
			out.watertight = false
		}
		if geoms[i].self_intersecting {
			out.self_intersecting = true
		}
	}
	// Coincident operands (identical geometry) weld a non-manifold doubled seam.
	for i in 0 ..< len(geoms) {
		for j in i + 1 ..< len(geoms) {
			if fpm_coincident(geoms[i], geoms[j]) {
				out.watertight = false
			}
		}
	}
	return out
}

// fpm_difference_geometry subtracts every later operand from the base (the first
// operand). The result volume is the base volume minus the subtrahends (floored
// at zero); when the subtrahends meet-or-exceed the base, the difference carves
// to zero volume — the §16.3 zero-volume case for a fully-carved difference. The
// triangle count and component count track the base (subtraction does not add
// disconnected parts). An open/self-intersecting base propagates.
fpm_difference_geometry :: proc(operands: []Fpm_Solid) -> Fpm_Geometry {
	base := fpm_geometry(operands[0])
	out := base
	carved := base.volume
	for i in 1 ..< len(operands) {
		sub := fpm_geometry(operands[i])
		carved -= sub.volume
		out.tris += sub.tris // a carve adds the cut surface's triangles
	}
	out.volume = max(carved, 0)
	return out
}

// fpm_intersect_geometry keeps the overlap of its operands. The overlap can never
// exceed the smallest operand's volume, so the result volume is bounded by the
// minimum; an empty operand (zero volume) makes the whole intersect empty (the
// §16.3 zero-volume case for a degenerate intersect). The triangle/component
// shape tracks the smallest operand (the overlap lives inside it).
fpm_intersect_geometry :: proc(operands: []Fpm_Solid) -> Fpm_Geometry {
	out := fpm_geometry(operands[0])
	min_vol := out.volume
	for i in 1 ..< len(operands) {
		g := fpm_geometry(operands[i])
		if g.volume < min_vol {
			min_vol = g.volume
			out = g
		}
		if g.self_intersecting {
			out.self_intersecting = true
		}
	}
	out.volume = min_vol
	return out
}

// fpm_coincident reports whether two geometry digests are identical to within the
// volume floor — the signal of a coincident (doubled) surface in a union, the
// non-manifold seam case. Identical volume and triangle count is the digest-level
// proxy for "the same surface in the same place" (§16 §6 diffs the digest, not
// coordinates).
fpm_coincident :: proc(a, b: Fpm_Geometry) -> bool {
	return a.tris == b.tris && math.abs(a.volume - b.volume) < MIN_VOLUME && a.volume >= MIN_VOLUME
}

// fpm_radial_segments is the canonical radial segment count for a curved
// primitive of the given radius: SEGMENTS_PER_UNIT per unit radius, floored at
// MIN_SEGMENTS so a tiny primitive still tessellates as a closed surface. The
// count scales with size so an oversized primitive crosses the triangle budget
// (the §16.3 over-budget gate) while a rig-scale one stays well under it.
fpm_radial_segments :: proc(r: f64) -> int {
	seg := int(r * SEGMENTS_PER_UNIT)
	return max(seg, MIN_SEGMENTS)
}

// fpm_sphere_tris is the triangle count of a UV-sphere/capsule cap at the
// radius's canonical tessellation: an N×N latitude-longitude grid is 2·N²
// triangles.
fpm_sphere_tris :: proc(r: f64) -> int {
	seg := fpm_radial_segments(r)
	return 2 * seg * seg
}

// fpm_degenerate reports whether a folded dimension is a real zero-or-negative
// (a degenerate sizing). The -1 sentinel an UNKNOWN (param-driven) dimension
// carries is NOT degenerate — fpm_dim maps it to a unit nominal size before this
// is reached — so only a literal zero/negative trips it.
fpm_degenerate :: proc(dim: f64) -> bool {
	return dim <= 0
}

// fpm_dim reads a primitive's i-th folded dimension, mapping the -1 UNKNOWN
// sentinel (a param-driven sizing the parser could not fold) to a unit nominal
// size of 1.0 so an unresolved param does not false-trip the zero-volume gate. A
// missing dimension (fewer args than the primitive's arity) reads as 0 — a
// genuinely under-sized constructor, which is degenerate.
fpm_dim :: proc(dims: []f64, i: int) -> f64 {
	if i >= len(dims) {
		return 0
	}
	if dims[i] < 0 {
		return 1 // UNKNOWN (param-driven) — nominal unit size, not degenerate
	}
	return dims[i]
}

// fpm_degenerate_geometry is the digest of a zero-volume mesh: no volume, no
// triangles, no components, and watertight (a degenerate solid is not
// non-manifold — it is empty, the zero-volume case). Returning a single shared
// shape keeps every degenerate path (a zero primitive, a fully-carved difference,
// an empty intersect, a collapsed scale) scoring identically.
fpm_degenerate_geometry :: proc() -> Fpm_Geometry {
	return Fpm_Geometry{volume = 0, tris = 0, components = 0, watertight = true}
}
