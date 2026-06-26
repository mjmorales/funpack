// The .gen.fun rig-seam emitter: the modeling pipeline's source-TEXT serializer
// for a parsed+gated `rig` Fpm_Unit (fpm_parser.odin) → the committed
// gen/<stem>.gen.fun seam. It is the modeling analogue of gen_emit.odin (the
// levels/assets seam emitter) for the rig form the krognid example bakes, and the
// byte target is the committed exemplar
// examples/krognid/gen/krognid.gen.fun.
//
// DISTINCT FROM gen_emit.odin: that emitter renders the `data`/`extern fn`
// declaration shape the levels/assets seams use; the rig seam is two body-bearing
// `@gtag("rig")`-tagged `fn`s (a skeleton factory and a part-binding chain) and a
// brace-less single-symbol import (`import engine.assets.mesh`), neither of which
// the Seam_Decl_Kind union models. This file reuses gen_emit.odin's shared @doc
// line emitter (emit_seam_doc) and adds the rig-fn body emission locally, so the
// two pipelines share the file-leading-@doc byte contract without forcing the rig
// form into the data/extern union.
//
// PURE FIXED-POINT SEAM (§16 §8): no float crosses the seam — the .fpm bake fns
// computed geometry in the float domain, but the emitted seam is a skeleton
// factory and slot→mesh-handle bindings, all fixed-point/handle .fun the sim
// imports. The emitter never writes a coordinate.
//
// PURITY (spec §09, §29): emission is a pure function of the Rig_Seam model. The
// projection rig_seam_of_unit derives the slot bindings, mesh names, and mirror
// from the parsed rig in declaration order; the file-leading and digest @doc
// strings are bake metadata the model carries (the rest-pose digest's rest-bbox
// and post-mirror count are functions of the engine skeleton's rest geometry the
// frontend does not model, so they ride the seam as the upstream bake computed
// them). Two emissions of the same model are byte-identical.
package funpack

import "core:strings"

// Rig_Seam is the in-memory model of one rig .gen.fun seam (§16 §7): the
// file-leading @doc, the ordered import list, and the two @doc + @gtag("rig")
// headed fn declarations — a skeleton factory and a part-binding chain. It is the
// explicit byte contract the rig baker fills and the emitter renders; order is
// significant (imports and binds emit in slice order, so a deterministic bake
// yields deterministic bytes).
Rig_Seam :: struct {
	// doc is the file-leading @doc content (text inside @doc("…"), unescaped). It
	// always heads the seam.
	doc:      string,
	// imports are the seam's `import` lines in declaration order: the braced
	// engine.anim members first, then the brace-less engine.assets.mesh constructor.
	imports:  []Rig_Import,
	// skeleton is the `@gtag("rig") fn <name>() -> Skeleton { return <factory>() }`
	// declaration: the named topology factory.
	skeleton: Rig_Skeleton_Fn,
	// parts is the `@gtag("rig") fn <name>() -> PartSet { return PartSet.empty()…}`
	// declaration: the slot→mesh-handle bind chain plus the trailing mirror.
	parts:    Rig_Parts_Fn,
}

// Rig_Import is one seam import line. `braced` selects the form: true emits the
// `import <path>.{m0, m1}` multi-member brace list (engine.anim's types), false
// emits the brace-less single-symbol `import <path>.<member>` (engine.assets.mesh,
// a bare constructor import). The brace-less form is why the rig seam cannot reuse
// gen_emit.odin's always-braced emit_seam_import.
Rig_Import :: struct {
	path:    string,   // the dotted module path before the member(s)
	members: []string, // the imported names; one member when braced is false
	braced:  bool,     // true => `.{m0, m1}` brace list; false => `.member` bare symbol
}

// Rig_Skeleton_Fn is the `@gtag("rig") fn <name>() -> Skeleton { return
// Skeleton.<factory>() }` declaration: its @doc (the rest-pose digest header), the
// fn name, and the named skeleton factory the body returns (`humanoid`).
Rig_Skeleton_Fn :: struct {
	doc:     string, // the @doc digest header (bone/part counts, rest-bbox, pivots-verified)
	name:    string, // the fn name (e.g. krognid_skeleton)
	factory: string, // the Skeleton factory the body returns (humanoid/quadruped/robot)
}

// Rig_Parts_Fn is the `@gtag("rig") fn <name>() -> PartSet { return
// PartSet.empty().bind(…)….mirror(…) }` declaration: its @doc, the fn name, the
// ordered slot→mesh-handle binds, and the optional trailing mirror.
Rig_Parts_Fn :: struct {
	doc:        string, // the @doc header for the part-binding chain
	name:       string, // the fn name (e.g. krognid_parts)
	binds:      []Rig_Slot_Bind, // the slot→mesh binds in declaration order
	mirror:     Rig_Mirror,       // the trailing .mirror(Side::from, Side::to)
	has_mirror: bool,             // whether the chain ends in a .mirror call
}

// Rig_Slot_Bind is one `.bind(Slot::<slot>, mesh("<asset>"))` link in the part
// chain: the PascalCase Slot the part attaches to and the manifest-checked mesh
// asset name it binds. The mesh asset name's closed-registry check is the asset
// pipeline's (cross-epic); this seam emits the name the bind references.
Rig_Slot_Bind :: struct {
	slot: string, // the PascalCase Slot (e.g. LUpperArm)
	mesh: string, // the mesh asset name (e.g. krognid_upper_arm)
}

// Rig_Mirror is the trailing `.mirror(Side::<from>, Side::<to>)` of the part
// chain: the authored side mirrored onto the generated side at attach time.
Rig_Mirror :: struct {
	from: string, // the source side label (e.g. L)
	to:   string, // the generated side label (e.g. R)
}

// emit_rig_seam renders a Rig_Seam to canonical .gen.fun source bytes, matching the
// committed krognid exemplar byte-for-byte. Layout: the file-leading @doc, a blank
// line, the import block, a blank line, the skeleton fn, a blank line, the parts
// fn. The output ends in exactly one trailing newline. The returned string is
// allocated in `allocator`.
emit_rig_seam :: proc(seam: Rig_Seam, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	emit_seam_doc(&b, seam.doc)
	// Blank line between the file-leading @doc and the import block (the rig seam's
	// formatter-canonical header spacing).
	strings.write_string(&b, "\n")
	for imp in seam.imports {
		emit_rig_import(&b, imp)
	}
	strings.write_string(&b, "\n")
	emit_rig_skeleton_fn(&b, seam.skeleton)
	strings.write_string(&b, "\n")
	emit_rig_parts_fn(&b, seam.parts)
	return strings.to_string(b)
}

// emit_rig_import writes one import line in the form its `braced` flag selects: the
// `import <path>.{m0, m1, …}` brace list, or the brace-less `import <path>.<member>`
// single-symbol form.
emit_rig_import :: proc(b: ^strings.Builder, imp: Rig_Import) {
	strings.write_string(b, "import ")
	strings.write_string(b, imp.path)
	if imp.braced {
		strings.write_string(b, ".{")
		for member, i in imp.members {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			strings.write_string(b, member)
		}
		strings.write_string(b, "}")
	} else {
		strings.write_string(b, ".")
		if len(imp.members) > 0 {
			strings.write_string(b, imp.members[0])
		}
	}
	strings.write_string(b, "\n")
}

// emit_rig_skeleton_fn writes the `@doc(…)` + `@gtag("rig")` headed skeleton fn:
// the doc line, the gtag line, the `fn <name>() -> Skeleton {` opener, a two-space
// indented `return Skeleton.<factory>()`, and the closing brace on its own line.
emit_rig_skeleton_fn :: proc(b: ^strings.Builder, fn: Rig_Skeleton_Fn) {
	emit_seam_doc(b, fn.doc)
	emit_rig_gtag(b)
	strings.write_string(b, "fn ")
	strings.write_string(b, fn.name)
	strings.write_string(b, "() -> Skeleton {\n")
	strings.write_string(b, "  return Skeleton.")
	strings.write_string(b, fn.factory)
	strings.write_string(b, "()\n")
	strings.write_string(b, "}\n")
}

// emit_rig_parts_fn writes the `@doc(…)` + `@gtag("rig")` headed parts fn: the doc
// and gtag lines, the `fn <name>() -> PartSet {` opener, the `return
// PartSet.empty()` chain head, then one four-space-indented `.bind(Slot::<slot>,
// mesh("<asset>"))` per bind with the mesh column aligned to the longest slot, the
// trailing `.mirror(Side::from, Side::to)` when present, and the closing brace.
emit_rig_parts_fn :: proc(b: ^strings.Builder, fn: Rig_Parts_Fn) {
	emit_seam_doc(b, fn.doc)
	emit_rig_gtag(b)
	strings.write_string(b, "fn ")
	strings.write_string(b, fn.name)
	strings.write_string(b, "() -> PartSet {\n")
	strings.write_string(b, "  return PartSet.empty()\n")
	longest := longest_slot_len(fn.binds)
	for bind in fn.binds {
		strings.write_string(b, "    .bind(Slot::")
		strings.write_string(b, bind.slot)
		strings.write_string(b, ",")
		// One space minimum after the comma, plus padding so every mesh( starts at
		// the longest-slot column.
		pad := longest - len(bind.slot) + 1
		for _ in 0 ..< pad {
			strings.write_string(b, " ")
		}
		strings.write_string(b, "mesh(\"")
		strings.write_string(b, bind.mesh)
		strings.write_string(b, "\"))\n")
	}
	if fn.has_mirror {
		strings.write_string(b, "    .mirror(Side::")
		strings.write_string(b, fn.mirror.from)
		strings.write_string(b, ", Side::")
		strings.write_string(b, fn.mirror.to)
		strings.write_string(b, ")\n")
	}
	strings.write_string(b, "}\n")
}

// emit_rig_gtag writes the `@gtag("rig")` line that classifies both seam fns under
// the rig generator tag (§16 §7) — the closed @gtag registry the index contract
// reads.
emit_rig_gtag :: proc(b: ^strings.Builder) {
	strings.write_string(b, "@gtag(\"rig\")\n")
}

// longest_slot_len returns the byte length of the longest Slot name across the
// binds — the alignment anchor for the .bind chain's mesh( column. Zero for an
// empty chain.
longest_slot_len :: proc(binds: []Rig_Slot_Bind) -> int {
	longest := 0
	for bind in binds {
		if len(bind.slot) > longest {
			longest = len(bind.slot)
		}
	}
	return longest
}

// ── Projection: parsed rig → seam model ──────────────────────────────────────

// rig_seam_of_unit projects a parsed+gated rig Fpm_Unit onto the Rig_Seam the
// emitter renders — the "fresh bake" of models/<stem>.fpm whose bytes a clean tree
// reproduces against the committed seam. It derives, in part-declaration order:
// each part's Slot (the bone's PascalCase slot from the named skeleton) and mesh
// asset name (`<module>_<part>`, the module-namespaced handle the asset pipeline
// registers), and the trailing mirror from the unit's first mirror directive. The
// fn names are `<module>_skeleton` / `<module>_parts`, the skeleton factory is the
// named topology. The seam-header and digest @doc strings are bake metadata the
// caller supplies (the rest-pose digest is a function of the engine skeleton's rest
// geometry the frontend does not model), so a faithful bake passes the committed
// docs through.
rig_seam_of_unit :: proc(
	unit: Fpm_Unit,
	module: string,
	file_doc: string,
	skeleton_doc: string,
	parts_doc: string,
	allocator := context.allocator,
) -> Rig_Seam {
	imports := make([]Rig_Import, 2, allocator)
	imports[0] = Rig_Import {
		path    = "engine.anim",
		members = slice_lit({"Skeleton", "PartSet", "Slot", "Side"}, allocator),
		braced  = true,
	}
	imports[1] = Rig_Import {
		path    = "engine.assets",
		members = slice_lit({"mesh"}, allocator),
		braced  = false,
	}

	binds := make([dynamic]Rig_Slot_Bind, 0, len(unit.binds), allocator)
	for bind in unit.binds {
		if bind.kind != .Part {
			continue
		}
		slot := fpm_bone_slot(bind.bone, allocator)
		append(&binds, Rig_Slot_Bind{slot = slot, mesh = strings.concatenate({module, "_", bind.name}, allocator)})
	}

	parts := Rig_Parts_Fn {
		doc   = parts_doc,
		name  = strings.concatenate({module, "_parts"}, allocator),
		binds = binds[:],
	}
	if len(unit.mirrors) > 0 {
		parts.has_mirror = true
		parts.mirror = Rig_Mirror{from = unit.mirrors[0].from, to = unit.mirrors[0].to}
	}

	return Rig_Seam {
		doc = file_doc,
		imports = imports,
		skeleton = Rig_Skeleton_Fn {
			doc = skeleton_doc,
			name = strings.concatenate({module, "_skeleton"}, allocator),
			factory = unit.skeleton,
		},
		parts = parts,
	}
}

// fpm_bone_slot maps a `at BONE` attach name to the PascalCase Slot the seam binds,
// via the named skeleton's bone table (`TORSO` => `Torso`, `L_UPPER_ARM` =>
// `LUpperArm`). A bone outside the modeled humanoid set falls back to a mechanical
// UPPER_SNAKE → PascalCase fold (e.g. `JOINT0` => `Joint0`), so a generic-joint
// part still projects a slot rather than dropping out of the chain.
fpm_bone_slot :: proc(attach: string, allocator := context.allocator) -> string {
	if bone, known := fpm_lookup_bone(attach); known {
		return bone.slot
	}
	return fpm_pascal_of_snake(attach, allocator)
}

// fpm_pascal_of_snake folds an UPPER_SNAKE bone name to PascalCase: split on '_',
// lowercase each segment, capitalize its first byte, and join. `L_UPPER_ARM` =>
// `LUpperArm`. It is the mechanical fallback for a bone not in the named skeleton's
// fixed slot table. The result clones into `allocator` (the one rig_seam_of_unit
// threads down) so a derived slot shares the seam's lifetime, not the global
// context's.
fpm_pascal_of_snake :: proc(snake: string, allocator := context.allocator) -> string {
	segments := strings.split(snake, "_", context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	for seg in segments {
		if len(seg) == 0 {
			continue
		}
		lowered := strings.to_lower(seg, context.temp_allocator)
		strings.write_string(&b, strings.to_upper(lowered[:1], context.temp_allocator))
		strings.write_string(&b, lowered[1:])
	}
	return strings.clone(strings.to_string(b), allocator)
}
