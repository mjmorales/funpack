package funpack

import "core:math"

MAX_TRIANGLES :: 100_000
DECOMPOSE_TRIANGLES :: 20_000
MIN_VOLUME :: 1e-6

SEGMENTS_PER_UNIT :: 6
MIN_SEGMENTS :: 12

Fpm_Gate_Error :: enum {
	None,
	Non_Manifold,
	Self_Intersecting,
	Zero_Volume,
	Over_Budget,
}

Fpm_Gate_Warning :: enum {
	None,
	Should_Decompose,
}

Fpm_Gate_Verdict :: struct {
	err:     Fpm_Gate_Error,
	binding: string,
	warning: Fpm_Gate_Warning,
}

Fpm_Geometry :: struct {
	volume:            f64,
	tris:              int,
	components:        int,
	watertight:        bool,
	self_intersecting: bool,
}

stage_fpm_gates :: proc(unit: Fpm_Unit) -> Fpm_Gate_Error {
	return fpm_gate_verdict(unit).err
}

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

fpm_resolve_binding_solid :: proc(unit: Fpm_Unit, bind: Fpm_Bind) -> Fpm_Solid {
	if bind.solid != nil {
		return bind.solid
	}
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

fpm_geometry :: proc(solid: Fpm_Solid) -> Fpm_Geometry {
	switch s in solid {
	case ^Fpm_Primitive:
		return fpm_primitive_geometry(s)
	case ^Fpm_Transform:
		return fpm_transform_geometry(s)
	case ^Fpm_Boolean:
		return fpm_boolean_geometry(s)
	case nil:
		return Fpm_Geometry{components = 0, watertight = true}
	}
	return Fpm_Geometry{watertight = true}
}

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
		geom.tris = 12
	}
	return geom
}

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
	for i in 0 ..< len(geoms) {
		for j in i + 1 ..< len(geoms) {
			if fpm_coincident(geoms[i], geoms[j]) {
				out.watertight = false
			}
		}
	}
	return out
}

fpm_difference_geometry :: proc(operands: []Fpm_Solid) -> Fpm_Geometry {
	base := fpm_geometry(operands[0])
	out := base
	carved := base.volume
	for i in 1 ..< len(operands) {
		sub := fpm_geometry(operands[i])
		carved -= sub.volume
		out.tris += sub.tris
	}
	out.volume = max(carved, 0)
	return out
}

fpm_intersect_geometry :: proc(operands: []Fpm_Solid) -> Fpm_Geometry {
	out := fpm_geometry(operands[0])
	min_vol := out.volume
	watertight := out.watertight
	self_intersecting := out.self_intersecting
	for i in 1 ..< len(operands) {
		g := fpm_geometry(operands[i])
		if !g.watertight {
			watertight = false
		}
		if g.self_intersecting {
			self_intersecting = true
		}
		if g.volume < min_vol {
			min_vol = g.volume
			out = g
		}
	}
	out.volume = min_vol
	out.watertight = watertight
	out.self_intersecting = self_intersecting
	return out
}

fpm_coincident :: proc(a, b: Fpm_Geometry) -> bool {
	return a.tris == b.tris && math.abs(a.volume - b.volume) < MIN_VOLUME && a.volume >= MIN_VOLUME
}

fpm_radial_segments :: proc(r: f64) -> int {
	seg := int(r * SEGMENTS_PER_UNIT)
	return max(seg, MIN_SEGMENTS)
}

fpm_sphere_tris :: proc(r: f64) -> int {
	seg := fpm_radial_segments(r)
	return 2 * seg * seg
}

fpm_degenerate :: proc(dim: f64) -> bool {
	return dim <= 0
}

fpm_dim :: proc(dims: []f64, i: int) -> f64 {
	if i >= len(dims) {
		return 0
	}
	if dims[i] < 0 {
		return 1
	}
	return dims[i]
}

fpm_degenerate_geometry :: proc() -> Fpm_Geometry {
	return Fpm_Geometry{volume = 0, tris = 0, components = 0, watertight = true}
}
