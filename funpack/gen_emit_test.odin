package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

ARENA_GEN_DEFAULT_REL :: "examples/arena/gen/arena.gen.fun"

arena_seam :: proc(allocator := context.allocator) -> Seam {
	imports := make([]Seam_Import, 2, allocator)
	imports[0] = Seam_Import {
		path    = "engine.world",
		members = slice_lit({"Spawn", "Ref"}, allocator),
	}
	imports[1] = Seam_Import {
		path    = "arena_world",
		members = slice_lit({"Player", "Hunter", "Pillar", "Switch", "Door", "Base", "Cannon"}, allocator),
	}

	arena_turret_fields := make([]Seam_Field, 2, allocator)
	arena_turret_fields[0] = Seam_Field{name = "base", type = "Ref[Base]"}
	arena_turret_fields[1] = Seam_Field{name = "cannon", type = "Ref[Cannon]"}

	arena_fields := make([]Seam_Field, 6, allocator)
	arena_fields[0] = Seam_Field{name = "hero", type = "Ref[Player]"}
	arena_fields[1] = Seam_Field{name = "stalker", type = "Ref[Hunter]"}
	arena_fields[2] = Seam_Field{name = "plate", type = "Ref[Switch]"}
	arena_fields[3] = Seam_Field{name = "exit", type = "Ref[Door]"}
	arena_fields[4] = Seam_Field{name = "left_gun", type = "ArenaTurret"}
	arena_fields[5] = Seam_Field{name = "right_gun", type = "ArenaTurret"}

	declarations := make([]Seam_Decl, 4, allocator)
	declarations[0] = Seam_Decl {
		doc  = "A placed Turret prefab instance: typed references to its expanded members. Generated from the prefab in arena.flvl.",
		kind = Seam_Data{name = "ArenaTurret", multiline = false, fields = arena_turret_fields},
	}
	declarations[1] = Seam_Decl {
		doc  = "Typed references to the Arena level's named instances. Ids are derived from the level-qualified names, so these are stable across loads, saves, and replays. Generated from arena.flvl — edit the level, not this file.",
		kind = Seam_Data{name = "Arena", multiline = true, fields = arena_fields},
	}
	declarations[2] = Seam_Decl {
		doc  = "The deterministic spawn list for Arena, in declaration order (the prefab and the pillar loop expanded in place). Backed by arena.flvl.",
		kind = Seam_Extern_Fn{name = "arena_spawns", return_type = "[Spawn]"},
	}
	declarations[3] = Seam_Decl {
		doc  = "The Arena symbol table, valid once the level is loaded.",
		kind = Seam_Extern_Fn{name = "arena", return_type = "Arena"},
	}

	return Seam {
		doc = "Generated seam for levels/arena.flvl: typed references to the level's named instances and the deterministic spawn list, baked from the flat-text level. Imports the schema module only. Edit the level, not this file.",
		imports = imports,
		declarations = declarations,
	}
}

resolve_arena_gen_path :: proc() -> string {
	return resolve_spec_dir("FUNPACK_ARENA_GEN", ARENA_GEN_DEFAULT_REL)
}

@(test)
test_gen_emit_arena_byte_exact :: proc(t: ^testing.T) {
	path := resolve_arena_gen_path()
	golden_bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		log.warnf(
			"SKIP gen-emit arena: %s not found — set FUNPACK_ARENA_GEN or ensure the in-repo fixture exists",
			path,
		)
		return
	}
	golden := string(golden_bytes)

	emitted := emit_gen_fun(arena_seam(context.temp_allocator), context.temp_allocator)

	testing.expect_value(t, len(emitted), len(golden))
	testing.expect(t, emitted == golden)
	if emitted != golden {
		report_first_byte_diff(emitted, golden)
		return
	}
	log.infof("gen-emit golden: arena.gen.fun reproduces the exemplar byte-for-byte (%d bytes)", len(emitted))
}

@(test)
test_gen_emit_double_emit_identical :: proc(t: ^testing.T) {
	model := arena_seam(context.temp_allocator)
	first := emit_gen_fun(model, context.temp_allocator)
	second := emit_gen_fun(model, context.temp_allocator)
	testing.expect(t, first == second)
	testing.expect_value(t, len(first), len(second))
	if first == second {
		log.infof("gen-emit double emit: two arena seam emissions are byte-identical (deterministic emit, %d bytes)", len(first))
	}
}

@(test)
test_gen_emit_inline_data_layout :: proc(t: ^testing.T) {
	seam := Seam {
		doc = "d",
		imports = {Seam_Import{path = "engine.world", members = {"Ref"}}},
		declarations = {
			Seam_Decl {
				doc = "p",
				kind = Seam_Data {
					name = "Pair",
					multiline = false,
					fields = {
						Seam_Field{name = "a", type = "Ref[X]"},
						Seam_Field{name = "b", type = "Ref[Y]"},
					},
				},
			},
		},
	}
	expected := "@doc(\"d\")\n" + "import engine.world.{Ref}\n" + "\n" + "@doc(\"p\")\n" + "data Pair { a: Ref[X], b: Ref[Y] }\n"
	emitted := emit_gen_fun(seam, context.temp_allocator)
	testing.expect_value(t, len(emitted), len(expected))
	testing.expect(t, emitted == expected)
	if emitted != expected {
		report_first_byte_diff(emitted, expected)
	}
}

@(test)
test_gen_emit_multiline_alignment :: proc(t: ^testing.T) {
	seam := Seam {
		doc = "d",
		imports = {Seam_Import{path = "engine.world", members = {"Ref"}}},
		declarations = {
			Seam_Decl {
				doc = "s",
				kind = Seam_Data {
					name = "Sym",
					multiline = true,
					fields = {
						Seam_Field{name = "x", type = "Ref[A]"},
						Seam_Field{name = "longest", type = "Ref[B]"},
					},
				},
			},
		},
	}
	expected := "@doc(\"d\")\n" + "import engine.world.{Ref}\n" + "\n" + "@doc(\"s\")\n" + "data Sym {\n" + "  x:       Ref[A]\n" + "  longest: Ref[B]\n" + "}\n"
	emitted := emit_gen_fun(seam, context.temp_allocator)
	testing.expect_value(t, len(emitted), len(expected))
	testing.expect(t, emitted == expected)
	if emitted != expected {
		report_first_byte_diff(emitted, expected)
	}
}

@(test)
test_resolve_arena_gen_path_is_absolute :: proc(t: ^testing.T) {
	testing.expect(t, filepath.is_abs(resolve_arena_gen_path()))
}
