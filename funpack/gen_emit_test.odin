// The .gen.fun seam-emitter golden: a hand-built Seam model corresponding to the
// committed exemplar funpack-spec/examples/arena/gen/arena.gen.fun, emitted
// through emit_gen_fun, must reproduce that exemplar byte-for-byte, and emitting
// the same model twice must be byte-identical (spec §09/§29 purity). The model
// is built BY HAND here — never parsed from the file — so the test pins the
// emitter's byte contract, not a round-trip. Like the artifact golden
// (golden_emit_test.odin), it resolves the live exemplar (or FUNPACK_ARENA_GEN)
// and SKIPs loudly when the funpack-spec sibling is absent; a skipped golden is
// a warning, never a pass.
package funpack

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

// ARENA_GEN_DEFAULT_REL is the committed exemplar's path relative to the main
// checkout root (one level up from this package), resolved through
// resolve_spec_dir so it survives an orchestrator task-worktree #directory.
ARENA_GEN_DEFAULT_REL :: "../funpack-spec/examples/arena/gen/arena.gen.fun"

// arena_seam builds, by hand, the Seam model that corresponds exactly to the
// committed arena.gen.fun exemplar: the file-leading @doc, the engine + schema
// imports, the inline ArenaTurret prefab record, the aligned-multiline Arena
// symbol table, and the two extern-fn accessors — all in the exemplar's
// declaration order. This is the byte contract's input; the exemplar is its
// expected output. The em-dash in the Arena doc is the exemplar's literal UTF-8
// em-dash, kept verbatim so the byte comparison exercises multibyte content.
//
// The nested slices are allocated into `allocator` (Odin forbids returning a
// stack-backed compound-literal slice), so the returned Seam outlives this call.
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

// slice_lit copies a fixed-array literal into an allocator-backed slice, so a
// Seam carrying it can be returned from a proc without dangling into the caller's
// stack frame.
slice_lit :: proc(items: []string, allocator := context.allocator) -> []string {
	out := make([]string, len(items), allocator)
	copy(out, items)
	return out
}

// resolve_arena_gen_path resolves the committed arena.gen.fun exemplar: the
// FUNPACK_ARENA_GEN env override when set, else the sibling-checkout default
// anchored at the main checkout root (resolve_spec_dir handles the worktree
// infix). The path points at the file, not a directory.
resolve_arena_gen_path :: proc() -> string {
	return resolve_spec_dir("FUNPACK_ARENA_GEN", ARENA_GEN_DEFAULT_REL)
}

// test_gen_emit_arena_byte_exact is the load-bearing acceptance: the hand-built
// arena Seam model, emitted through emit_gen_fun, reproduces the committed
// arena.gen.fun exemplar byte-for-byte. A diff in any byte — a doc character,
// an import member, a field-alignment space, the trailing newline — fails here.
// SKIPs loudly when the funpack-spec sibling is absent (a skipped golden is not
// a pass).
@(test)
test_gen_emit_arena_byte_exact :: proc(t: ^testing.T) {
	path := resolve_arena_gen_path()
	golden_bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		log.warnf(
			"SKIP gen-emit arena: %s not found — set FUNPACK_ARENA_GEN or check out funpack-spec as a sibling of the repo",
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
	// odin test echoes a name only on failure, so announce the byte match so a
	// passing run leaves a trace the acceptance gate can read.
	log.infof("gen-emit golden: arena.gen.fun reproduces the exemplar byte-for-byte (%d bytes)", len(emitted))
}

// test_gen_emit_double_emit_identical proves emission is deterministic (spec
// §09, §29): two emissions of the same hand-built model are byte-identical, so
// the seam bytes carry no field whose value depends on when, where, or on which
// machine they were emitted. Self-contained — no golden checkout needed.
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

// test_gen_emit_inline_data_layout pins the single-line data layout in
// isolation: a multiline=false record emits `data Name { f: T, g: U }` with one
// space inside each brace and ", " between fields. Self-contained, so the inline
// layout's byte shape is fixed even without the golden checkout.
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

// test_gen_emit_multiline_alignment pins the aligned-multiline layout in
// isolation: a multiline=true record indents every field two spaces and pads
// after the colon so the type column aligns to the longest field name. The
// short name gets more padding than the long one, both types landing at the
// same column. Self-contained.
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
	// longest name is "longest" (7); type column = 2 indent + 7 + 1 space = 10.
	// x: 1 char -> (7-1)+1 = 7 spaces after colon; longest -> (7-7)+1 = 1 space.
	expected := "@doc(\"d\")\n" + "import engine.world.{Ref}\n" + "\n" + "@doc(\"s\")\n" + "data Sym {\n" + "  x:       Ref[A]\n" + "  longest: Ref[B]\n" + "}\n"
	emitted := emit_gen_fun(seam, context.temp_allocator)
	testing.expect_value(t, len(emitted), len(expected))
	testing.expect(t, emitted == expected)
	if emitted != expected {
		report_first_byte_diff(emitted, expected)
	}
}

// test_resolve_arena_gen_path_is_absolute keeps the exemplar resolver honest:
// the resolved path is absolute (so a bare `odin test .` from any cwd, and a
// worktree validation run, resolve the same sibling file).
@(test)
test_resolve_arena_gen_path_is_absolute :: proc(t: ^testing.T) {
	testing.expect(t, filepath.is_abs(resolve_arena_gen_path()))
}
