package funpack

import "core:strings"

Fpm_Rig_Error :: enum {
	None,
	Part_Pivot_Mismatch,
	Unbound_Slot,
	Duplicate_Mirrored_Side,
}

Fpm_Rig_Warning :: enum {
	None,
	Below_Clearance,
}

Fpm_Rig_Digest :: struct {
	bones:            int,
	parts:            int,
	parts_mirrored:   int,
	pivots_verified:  bool,
}

Fpm_Rig_Verdict :: struct {
	err:     Fpm_Rig_Error,
	part:    string,
	warning: Fpm_Rig_Warning,
	digest:  Fpm_Rig_Digest,
}

Fpm_Pivot_Class :: enum {
	Up_Rooted,
	Down_Rooted,
	Centered,
}

Fpm_Skeleton_Bone :: struct {
	attach: string,
	slot:   string,
	pivot:  Fpm_Pivot_Class,
}

@(rodata)
HUMANOID_BONES := []Fpm_Skeleton_Bone {
	{attach = "HIPS", slot = "Hips", pivot = .Up_Rooted},
	{attach = "TORSO", slot = "Torso", pivot = .Up_Rooted},
	{attach = "NECK", slot = "Neck", pivot = .Up_Rooted},
	{attach = "HEAD", slot = "Head", pivot = .Centered},
	{attach = "L_UPPER_ARM", slot = "LUpperArm", pivot = .Down_Rooted},
	{attach = "L_LOWER_ARM", slot = "LLowerArm", pivot = .Down_Rooted},
	{attach = "L_HAND", slot = "LHand", pivot = .Down_Rooted},
	{attach = "L_UPPER_LEG", slot = "LUpperLeg", pivot = .Down_Rooted},
	{attach = "L_LOWER_LEG", slot = "LLowerLeg", pivot = .Down_Rooted},
	{attach = "L_FOOT", slot = "LFoot", pivot = .Down_Rooted},
}

HUMANOID_BONE_COUNT :: 16

stage_fpm_rig_gates :: proc(unit: Fpm_Unit) -> Fpm_Rig_Error {
	return fpm_rig_verdict(unit).err
}

fpm_rig_verdict :: proc(unit: Fpm_Unit) -> Fpm_Rig_Verdict {
	mirrored := fpm_mirrored_prefixes(unit.mirrors)
	pivots_ok := true
	for bind in unit.binds {
		if bind.kind != .Part {
			continue
		}
		if fpm_is_mirrored_bone(bind.bone, mirrored) {
			return Fpm_Rig_Verdict{err = .Duplicate_Mirrored_Side, part = bind.name, digest = fpm_rig_digest(unit, false)}
		}
		if fpm_resolve_binding_solid(unit, bind) == nil {
			return Fpm_Rig_Verdict{err = .Unbound_Slot, part = bind.name, digest = fpm_rig_digest(unit, false)}
		}
		if !fpm_part_pivot_ok(unit, bind) {
			return Fpm_Rig_Verdict{err = .Part_Pivot_Mismatch, part = bind.name, digest = fpm_rig_digest(unit, false)}
		}
	}
	warning := Fpm_Rig_Warning.None
	if unit.has_clearance && fpm_min_joint_gap(unit) < unit.clearance {
		warning = .Below_Clearance
	}
	return Fpm_Rig_Verdict{err = .None, warning = warning, digest = fpm_rig_digest(unit, pivots_ok)}
}

fpm_part_pivot_ok :: proc(unit: Fpm_Unit, bind: Fpm_Bind) -> bool {
	bone, known := fpm_lookup_bone(bind.bone)
	if !known {
		return true
	}
	solid := fpm_resolve_binding_solid(unit, bind)
	actual := fpm_part_pivot_class(solid)
	return actual == bone.pivot
}

fpm_part_pivot_class :: proc(solid: Fpm_Solid) -> Fpm_Pivot_Class {
	if xf, is_xf := solid.(^Fpm_Transform); is_xf {
		#partial switch xf.kind {
		case .Down:
			return .Down_Rooted
		case .Up:
			return .Up_Rooted
		}
	}
	return .Centered
}

fpm_lookup_bone :: proc(attach: string) -> (bone: Fpm_Skeleton_Bone, known: bool) {
	for candidate in HUMANOID_BONES {
		if candidate.attach == attach {
			return candidate, true
		}
	}
	return {}, false
}

fpm_mirrored_prefixes :: proc(mirrors: []Fpm_Mirror) -> []string {
	out := make([dynamic]string, 0, len(mirrors), context.temp_allocator)
	for m in mirrors {
		append(&out, m.to)
	}
	return out[:]
}

fpm_is_mirrored_bone :: proc(attach: string, mirrored: []string) -> bool {
	for side in mirrored {
		if strings.has_prefix(attach, side) && len(attach) > len(side) && attach[len(side)] == '_' {
			return true
		}
	}
	return false
}

fpm_min_joint_gap :: proc(unit: Fpm_Unit) -> f64 {
	tightest := max(f64)
	for bind in unit.binds {
		if bind.kind != .Part {
			continue
		}
		solid := fpm_resolve_binding_solid(unit, bind)
		gap, ok := fpm_part_joint_gap(solid)
		if ok && gap < tightest {
			tightest = gap
		}
	}
	return tightest
}

fpm_part_joint_gap :: proc(solid: Fpm_Solid) -> (gap: f64, ok: bool) {
	prim := fpm_innermost_primitive(solid)
	if prim == nil || prim.kind != .Capsule {
		return 0, false
	}
	if len(prim.dims) < 2 || prim.dims[0] < 0 || prim.dims[1] < 0 {
		return 0, false
	}
	return prim.dims[1] - prim.dims[0], true
}

fpm_innermost_primitive :: proc(solid: Fpm_Solid) -> ^Fpm_Primitive {
	cursor := solid
	for {
		switch s in cursor {
		case ^Fpm_Primitive:
			return s
		case ^Fpm_Transform:
			cursor = s.inner
		case ^Fpm_Boolean:
			return nil
		case nil:
			return nil
		}
	}
}

fpm_rig_digest :: proc(unit: Fpm_Unit, pivots_verified: bool) -> Fpm_Rig_Digest {
	parts := 0
	for bind in unit.binds {
		if bind.kind == .Part {
			parts += 1
		}
	}
	return Fpm_Rig_Digest {
		bones = fpm_skeleton_bone_count(unit.skeleton),
		parts = parts,
		parts_mirrored = fpm_parts_after_mirror(unit),
		pivots_verified = pivots_verified,
	}
}

fpm_skeleton_bone_count :: proc(skeleton: string) -> int {
	if skeleton == "humanoid" {
		return HUMANOID_BONE_COUNT
	}
	return 0
}

fpm_parts_after_mirror :: proc(unit: Fpm_Unit) -> int {
	mirror_sources := fpm_mirror_source_prefixes(unit.mirrors)
	total := 0
	for bind in unit.binds {
		if bind.kind != .Part {
			continue
		}
		total += 1
		if fpm_is_mirrored_bone(bind.bone, mirror_sources) {
			total += 1
		}
	}
	return total
}

fpm_mirror_source_prefixes :: proc(mirrors: []Fpm_Mirror) -> []string {
	out := make([dynamic]string, 0, len(mirrors), context.temp_allocator)
	for m in mirrors {
		append(&out, m.from)
	}
	return out[:]
}
