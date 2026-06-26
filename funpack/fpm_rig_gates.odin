// The §16.7 rig gate stage for the modeling DSL (.fpm) — the rig-specific
// extension of P5 the spec calls out (§16 §7, "Validation gates (extending P5 to
// rigs)"). It scores a `rig` Fpm_Unit (fpm_parser.odin), AFTER the §16.3 geometry
// gates (fpm_gates.odin) have passed each part's mesh, against the four rig
// invariants and computes the reviewable rest-pose digest:
//
//   - part origin == declared bone pivot   (ERROR — Part_Pivot_Mismatch)
//   - every bound slot has a mesh          (ERROR — Unbound_Slot)
//   - mirrored side declared not duplicated(ERROR — Duplicate_Mirrored_Side)
//   - joint clearance >= clearance         (WARNING — Below_Clearance)
//   - rest-pose manifold / bounds          (DIGEST — Rig_Digest, the @doc fingerprint)
//
// PURITY (spec §09, §29): the gate is a pure function of the parsed unit and the
// named skeleton's fixed bone table — no float beyond the literal sizing the
// parser already folded, no host bytes. The skeleton's bone set, per-bone pivot
// discipline, and slot map are compiler constants for a named topology
// (`skeleton: humanoid`), mirroring fpm_gates.odin's fixed-budget discipline: a
// rig verdict is reproducible from the source alone.
//
// SCOPE: this gate scores the rig STRUCTURE — pivots, slot coverage, mirror
// non-duplication, clearance — and emits the digest the seam header carries. It
// does NOT score geometry (fpm_gates.odin's job, run first) and does NOT emit the
// seam (fpm_emit.odin's job, run on a clean verdict).

package funpack

import "core:strings"

// Fpm_Rig_Error is closed with one dedicated arm per §16.7 hard rig invariant and
// NO catch-all (mirroring Fpm_Gate_Error, fpm_gates.odin): a rig violation names
// exactly which invariant the rig broke. The soft clearance guidance is NOT an arm
// here — it is a warning (Fpm_Rig_Warning), kept off the fail enum so a
// warn-level finding can never be confused with a hard fail.
Fpm_Rig_Error :: enum {
	None,
	// Part_Pivot_Mismatch: a part's modeled (0,0,0) does not sit at its declared
	// bone's pivot. Each humanoid bone has a fixed pivot discipline — an axis/root
	// bone (Torso/Hips/Neck) carries a part that extends UP from the joint
	// (origin-rooted via `.up`), a limb bone (an arm/leg) carries a part that hangs
	// DOWN from its proximal joint (`.down(h)`), a terminal bone (Head) carries a
	// centered primitive. A part whose outermost placement transform contradicts its
	// bone's discipline displaces the joint off the modeled origin — the §16.7
	// pivot error.
	Part_Pivot_Mismatch,
	// Unbound_Slot: a part binding resolves to no mesh geometry — a `part name at
	// BONE = <expr>` whose value does not lift to a Solid (an empty or non-geometry
	// binding). Every bound slot must carry a mesh (§16.7).
	Unbound_Slot,
	// Duplicate_Mirrored_Side: a part is authored on the generated side of a mirror
	// — a `part ... at R_*` bone alongside a `mirror L -> R` directive. The mirror
	// GENERATES the right side from the left, so authoring it too is a redundant
	// double-definition the spec rejects (§16.7).
	Duplicate_Mirrored_Side,
}

// Fpm_Rig_Warning is the closed SOFT-guidance set (§16.7): a finding the bake
// surfaces but does NOT fail on. Below_Clearance fires when a declared `clearance
// N` floor is not met by the rig's tightest modeled joint gap — the rig is
// bakeable, but a joint sits closer than the authored minimum. Keeping warnings in
// a separate enum makes the warn-vs-fail distinction structural.
Fpm_Rig_Warning :: enum {
	None,
	Below_Clearance,
}

// Fpm_Rig_Digest is the §16.7 rest-pose fingerprint the seam's @doc header carries
// in place of triangle soup (§16 §6): the named skeleton's bone count, the part
// count before and after the mirror expansion, and a pivots-verified flag. It is a
// compact deterministic projection of the parsed rig, diffed in a review instead of
// coordinates. The rest-bbox is part of the conceptual digest (§16 §6) but is a
// function of the engine skeleton's rest geometry the frontend does not model, so
// it is carried as authored bake metadata on the seam, not recomputed here.
Fpm_Rig_Digest :: struct {
	bones:            int,  // the named skeleton's bone count (humanoid => 16)
	parts:            int,  // bound part count before mirror expansion
	parts_mirrored:   int,  // bound part count after the mirror expansion
	pivots_verified:  bool, // every part origin matched its bone pivot (the pivot gate passed)
}

// Fpm_Rig_Verdict is the full §16.7 rig-gate result for one rig unit: the first
// hard error (None when clean), the offending part's name (the diagnostic anchor),
// any soft warning, and the rest-pose digest. The hard error and the warning are
// independent: a rig can be clean (err == None) and still WARN (Below_Clearance).
// The digest is always computed (it heads the seam regardless of warnings).
Fpm_Rig_Verdict :: struct {
	err:     Fpm_Rig_Error,
	part:    string, // the offending part binding's name (the diagnostic anchor); "" when clean
	warning: Fpm_Rig_Warning,
	digest:  Fpm_Rig_Digest,
}

// Fpm_Pivot_Class is the closed per-bone pivot discipline a part attached to that
// bone must satisfy (§16.7). Up_Rooted: the part extends +Z from the joint at the
// modeled origin (an axis/root bone — Torso/Hips/Neck), authored as `.up(z)`.
// Down_Rooted: the part hangs -Z from its proximal joint at the modeled origin (a
// limb — arm/leg), authored as `.down(h)`. Centered: the part is a primitive
// centered on the joint (a terminal bone — Head), authored with no displacing
// placement transform.
Fpm_Pivot_Class :: enum {
	Up_Rooted,
	Down_Rooted,
	Centered,
}

// Fpm_Skeleton_Bone is one bone of a named skeleton: its UPPER_SNAKE attach name
// as written in a `part ... at BONE` clause (`TORSO`, `L_UPPER_ARM`), the
// PascalCase Slot the seam binds (`Torso`, `LUpperArm`), and the pivot class a part
// on it must satisfy. The frontend models only the attach-relevant facets of the
// engine skeleton — enough to gate pivots and project the seam's slot bindings.
Fpm_Skeleton_Bone :: struct {
	attach: string,          // the `at BONE` attach name (UPPER_SNAKE)
	slot:   string,          // the PascalCase Slot the seam binds
	pivot:  Fpm_Pivot_Class, // the pivot discipline a part on this bone must satisfy
}

// HUMANOID_BONES is the standard 16-bone humanoid skeleton's left/central bones in
// the order the krognid example authors them — the closed table the §16.7 rig gate
// scores against and the seam emitter projects slots from. It mirrors
// stdlib/engine/anim.fun's `enum Bone` (16 humanoid bones: Hips, Torso, Neck,
// Head, and the L/R limb pairs); only the LEFT and CENTRAL bones appear as attach
// points because the right side is generated by `mirror L -> R`. Authoring a part
// at a right-side bone (`R_UPPER_ARM`) alongside the mirror is the
// Duplicate_Mirrored_Side error.
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

// HUMANOID_BONE_COUNT is the named humanoid topology's full bone count (§16.7
// digest, mirroring stdlib/engine/anim.fun's 16 humanoid bones — the L/R limb
// pairs plus Hips/Torso/Neck/Head). It is the bone-count digest field, fixed for
// the named topology rather than derived from the authored part set (a rig may bind
// fewer parts than the skeleton has bones).
HUMANOID_BONE_COUNT :: 16

// stage_fpm_rig_gates is the pipeline seam: it returns just the first hard rig
// error a rig unit overshoots (the form a bake driver consumes), mirroring
// stage_fpm_gates for the geometry gate. The offending part, the warning, and the
// digest ride the full verdict (fpm_rig_verdict).
stage_fpm_rig_gates :: proc(unit: Fpm_Unit) -> Fpm_Rig_Error {
	return fpm_rig_verdict(unit).err
}

// fpm_rig_verdict scores a rig unit against the §16.7 hard invariants in a fixed
// order — duplicate-mirrored-side, then per-part pivot/mesh — returning the FIRST
// hard error in part-declaration order (so a multi-violation rig always reports the
// same first offender), naming the offending part. It also computes the soft
// clearance warning and the rest-pose digest. The hard error, the warning, and the
// digest are independent: a rig can be clean and still warn, and the digest is
// always computed.
//
// PRECONDITION: the unit is a `rig` block whose parts' geometry already passed the
// §16.3 geometry gate (fpm_gate_verdict). This gate scores structure, not geometry.
fpm_rig_verdict :: proc(unit: Fpm_Unit) -> Fpm_Rig_Verdict {
	mirrored := fpm_mirrored_prefixes(unit.mirrors)
	pivots_ok := true
	for bind in unit.binds {
		if bind.kind != .Part {
			continue
		}
		// A part authored at a bone on a mirror's GENERATED side is a redundant
		// double-definition (the mirror generates that side).
		if fpm_is_mirrored_bone(bind.bone, mirrored) {
			return Fpm_Rig_Verdict{err = .Duplicate_Mirrored_Side, part = bind.name, digest = fpm_rig_digest(unit, false)}
		}
		// A part binding must resolve to mesh geometry — an empty/non-geometry
		// binding leaves the slot unbound.
		if fpm_resolve_binding_solid(unit, bind) == nil {
			return Fpm_Rig_Verdict{err = .Unbound_Slot, part = bind.name, digest = fpm_rig_digest(unit, false)}
		}
		// The part's modeled origin must sit at its bone's declared pivot — the
		// part's outermost placement transform must match the bone's pivot class.
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

// fpm_part_pivot_ok scores one part's modeled origin against its bone's pivot
// discipline (§16.7). The part's outermost placement transform (the head of its
// resolved Solid) reveals where the geometry sits relative to the modeled origin: a
// `.down(h)` hangs the geometry below origin (the proximal joint at origin — a
// limb), a `.up(z)` extends it above (an axis/root bone), and a bare primitive sits
// centered on origin (a terminal bone). The bone's Fpm_Pivot_Class fixes which is
// correct; a contradiction displaces the joint off the modeled origin. A part at an
// unknown bone (not in the named skeleton) passes the pivot check vacuously — that
// is the skeleton's concern, not the pivot gate's.
fpm_part_pivot_ok :: proc(unit: Fpm_Unit, bind: Fpm_Bind) -> bool {
	bone, known := fpm_lookup_bone(bind.bone)
	if !known {
		return true
	}
	solid := fpm_resolve_binding_solid(unit, bind)
	actual := fpm_part_pivot_class(solid)
	return actual == bone.pivot
}

// fpm_part_pivot_class reads a resolved part Solid's outermost placement transform
// into the pivot class it realizes. A `.down(...)` outermost transform is
// Down_Rooted (the geometry hangs below the modeled origin); a `.up(...)` is
// Up_Rooted (above); any other outermost form — a bare primitive, a `.scale`/
// `.rotate`/`.at`, a boolean — is Centered (no axial displacement of the joint off
// the origin). A nil solid is Centered (it has no displacing transform); the
// unbound-slot gate has already rejected a nil-solid part before this is reached.
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

// fpm_lookup_bone finds a bone by its `at BONE` attach name in the named humanoid
// skeleton, or known=false for a bone outside the modeled set (a right-side or
// generic-joint bone). The right-side bones are intentionally absent: a part
// authored at one alongside a mirror is the Duplicate_Mirrored_Side error, caught
// before this lookup.
fpm_lookup_bone :: proc(attach: string) -> (bone: Fpm_Skeleton_Bone, known: bool) {
	for candidate in HUMANOID_BONES {
		if candidate.attach == attach {
			return candidate, true
		}
	}
	return {}, false
}

// fpm_mirrored_prefixes collects the GENERATED-side labels of every mirror
// directive (the `to` of `mirror L -> R` is "R"), the prefixes a part must NOT be
// authored on. A rig with no mirror yields an empty set, so the
// duplicate-mirrored-side gate never fires.
fpm_mirrored_prefixes :: proc(mirrors: []Fpm_Mirror) -> []string {
	out := make([dynamic]string, 0, len(mirrors), context.temp_allocator)
	for m in mirrors {
		append(&out, m.to)
	}
	return out[:]
}

// fpm_is_mirrored_bone reports whether a bone's attach name sits on a mirror's
// generated side — its UPPER_SNAKE name leads with a generated-side label followed
// by '_' (`R_UPPER_ARM` for a `mirror L -> R`). The underscore boundary keeps a
// generated side label "R" from matching an unrelated bone that merely starts with
// R, so only the side-prefixed limb bones trip it.
fpm_is_mirrored_bone :: proc(attach: string, mirrored: []string) -> bool {
	for side in mirrored {
		// Test `side` then an explicit '_' boundary rather than joining `side_`
		// per iteration — the membership scan stays allocation-free.
		if strings.has_prefix(attach, side) && len(attach) > len(side) && attach[len(side)] == '_' {
			return true
		}
	}
	return false
}

// fpm_min_joint_gap returns the rig's tightest modeled joint gap — the smallest
// radial slack between adjacent limb segments, the §16.7 clearance the warning
// scores. A joint gap is modeled as the difference between a limb segment's length
// and its radius (a fatter or shorter segment crowds the next joint); the tightest
// across all part meshes is the rig's clearance. With no scorable limb geometry the
// gap is reported as +inf-equivalent (a large sentinel) so a rig that models no
// joints never falsely warns.
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

// fpm_part_joint_gap computes one limb part's modeled joint gap: a capsule limb's
// gap is its segment length minus its radius (the slack a joint has before the
// segment's body crowds it). It reads the innermost primitive of the part's Solid
// (the placement transform wraps it). A non-capsule part has no scored gap
// (ok=false) — only capsule limbs contribute to the clearance. A capsule whose
// sizing is PARAM-DRIVEN (the parser folded an unresolvable param to the -1 unknown
// sentinel) also has no scored gap: the frontend does not bake-evaluate params, so
// an unknown radius/length cannot be scored against the floor — it is skipped, not
// scored as the nominal unit size the geometry gate uses. Only a literal-sized
// capsule contributes a gap.
fpm_part_joint_gap :: proc(solid: Fpm_Solid) -> (gap: f64, ok: bool) {
	prim := fpm_innermost_primitive(solid)
	if prim == nil || prim.kind != .Capsule {
		return 0, false
	}
	if len(prim.dims) < 2 || prim.dims[0] < 0 || prim.dims[1] < 0 {
		return 0, false // unknown (param-driven) sizing — not scorable against the floor
	}
	return prim.dims[1] - prim.dims[0], true
}

// fpm_innermost_primitive unwraps a part's placement transforms to the primitive at
// its core (`capsule(r, h).down(h)` => the capsule). It follows transform inners
// only; a boolean or a bare primitive at the head returns the primitive (nil for a
// boolean, since a CSG limb has no single sizing the clearance reads).
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

// fpm_rig_digest computes the §16.7 rest-pose digest of a rig unit: the named
// skeleton's bone count, the bound part count before and after the mirror
// expansion, and the pivots-verified flag. The post-mirror count adds, for each
// authored part on a mirrorable (side-prefixed) bone, its generated counterpart.
// The bone count is the named topology's fixed count (humanoid => 16), not the
// authored part count — a rig may bind fewer parts than the skeleton has bones.
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

// fpm_skeleton_bone_count maps a named skeleton topology to its fixed bone count
// (§16.7 digest). humanoid is the 16-bone standard (stdlib/engine/anim.fun); an
// unnamed or unrecognized topology reports 0 (no named topology, no fixed count).
fpm_skeleton_bone_count :: proc(skeleton: string) -> int {
	if skeleton == "humanoid" {
		return HUMANOID_BONE_COUNT
	}
	return 0
}

// fpm_parts_after_mirror counts the rig's parts once the mirror directives have
// expanded: every authored part, plus a generated counterpart for each authored
// part whose bone sits on a mirrorable side. A part on a side-prefixed limb bone
// (`L_UPPER_ARM` under `mirror L -> R`) generates one right-side counterpart; a
// central part (Torso/Head) generates none. The order follows the parts'
// declaration order so the count is deterministic.
fpm_parts_after_mirror :: proc(unit: Fpm_Unit) -> int {
	mirror_sources := fpm_mirror_source_prefixes(unit.mirrors)
	total := 0
	for bind in unit.binds {
		if bind.kind != .Part {
			continue
		}
		total += 1
		if fpm_is_mirrored_bone(bind.bone, mirror_sources) {
			total += 1 // the mirror generates this part's counterpart on the other side
		}
	}
	return total
}

// fpm_mirror_source_prefixes collects the SOURCE-side labels of every mirror
// directive (the `from` of `mirror L -> R` is "L") — the prefixes whose authored
// parts the mirror expands onto the other side. Distinct from
// fpm_mirrored_prefixes, which collects the GENERATED (`to`) side the
// duplicate-side gate forbids.
fpm_mirror_source_prefixes :: proc(mirrors: []Fpm_Mirror) -> []string {
	out := make([dynamic]string, 0, len(mirrors), context.temp_allocator)
	for m in mirrors {
		append(&out, m.from)
	}
	return out[:]
}
