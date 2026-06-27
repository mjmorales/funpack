package funpack

import "core:strings"

Rig_Seam :: struct {
	doc:      string,
	imports:  []Rig_Import,
	skeleton: Rig_Skeleton_Fn,
	parts:    Rig_Parts_Fn,
}

Rig_Import :: struct {
	path:    string,
	members: []string,
	braced:  bool,
}

Rig_Skeleton_Fn :: struct {
	doc:     string,
	name:    string,
	factory: string,
}

Rig_Parts_Fn :: struct {
	doc:        string,
	name:       string,
	binds:      []Rig_Slot_Bind,
	mirror:     Rig_Mirror,
	has_mirror: bool,
}

Rig_Slot_Bind :: struct {
	slot: string,
	mesh: string,
}

Rig_Mirror :: struct {
	from: string,
	to:   string,
}

emit_rig_seam :: proc(seam: Rig_Seam, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	emit_seam_doc(&b, seam.doc)
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

emit_rig_gtag :: proc(b: ^strings.Builder) {
	strings.write_string(b, "@gtag(\"rig\")\n")
}

longest_slot_len :: proc(binds: []Rig_Slot_Bind) -> int {
	longest := 0
	for bind in binds {
		if len(bind.slot) > longest {
			longest = len(bind.slot)
		}
	}
	return longest
}

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

fpm_bone_slot :: proc(attach: string, allocator := context.allocator) -> string {
	if bone, known := fpm_lookup_bone(attach); known {
		return bone.slot
	}
	return fpm_pascal_of_snake(attach, allocator)
}

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
