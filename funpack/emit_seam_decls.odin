// The v15 cross-module DECLARATION CARRY: the emitter side that makes a
// multi-module game's schema sections self-contained. The entrypoint module
// (dungeon's dungeon_game) imports its world types from a sibling USER schema
// module (`import dungeon_world.{Player, Slime, Chest, Dir, Looted}`), but
// emit_enums/emit_data/emit_signals/emit_things walk the ENTRYPOINT AST alone —
// so the things the [setup] batch spawns, the enum a carried default names
// (`Dir::Down`), and the signal the routing consumes would all be absent from
// the artifact, and the runtime could neither spawn nor default a single
// dungeon row. This file collects the imported enum/data/signal/thing
// declarations into per-section slices the emitter appends AFTER the entrypoint
// module's own declarations, so the artifact carries the whole referenced
// schema with no funpack source on the runtime's path (spec §29).
//
// SCOPE: the carry covers exactly the entrypoint module's import closure — an
// imported member that names a declaration in a sibling module's AST. A sibling
// declaration the entrypoint never imports (the dungeon seam's `data Dungeon`
// symbol table) is NOT carried: its consumer is the deferred level-accessor
// extern, a later schema bump. Imported fns/consts ride the SEPARATE [functions]
// carry (emit_seam_fns.odin).
//
// PURITY (spec §09, §29): the carry is a pure function of the entrypoint AST and
// the sibling-module ASTs. The walk is import-declaration order then the
// import's brace-group member order — never a map iteration (module_asts is read
// by key only) — so the carried declarations land in a fixed order and two
// emissions are byte-identical.
package funpack

// Imported_Decls is the v15 cross-module declaration carry, one slice per
// schema section the artifact appends imported declarations to. Each slice is
// in import-declaration order then member order — the same deterministic walk
// the [functions] seam carry uses.
Imported_Decls :: struct {
	enums:   []Enum_Node,
	datas:   []Data_Node,
	signals: []Signal_Node,
	things:  []Thing_Node,
}

// collect_imported_decls collects the imported enum/data/signal/thing
// declarations the entrypoint module references from sibling USER modules.
// For each import whose leading segment names a present sibling module, every
// brace-group member is resolved against that module's per-kind declaration
// slices; a member that resolves to a type declaration lands in the matching
// Imported_Decls slice. A member that is a fn or a const resolves to none of
// the four kinds here and is left to the [functions] carry; a member naming
// nothing (a checked import never does — typecheck precedes emission) carries
// nothing. A nil/empty module_asts (the single-source path) carries nothing,
// so a single-module game's bytes move by the version stamp alone.
collect_imported_decls :: proc(entry_ast: Ast, module_asts: map[string]Ast) -> Imported_Decls {
	if len(module_asts) == 0 {
		return Imported_Decls{}
	}
	enums := make([dynamic]Enum_Node, 0, 2, context.temp_allocator)
	datas := make([dynamic]Data_Node, 0, 2, context.temp_allocator)
	signals := make([dynamic]Signal_Node, 0, 2, context.temp_allocator)
	things := make([dynamic]Thing_Node, 0, 4, context.temp_allocator)
	for import_node in entry_ast.imports {
		seam_module, members, is_user := imported_user_module(import_node, module_asts)
		if !is_user {
			continue
		}
		seam_ast := module_asts[seam_module]
		for member in members {
			if decl, found := find_enum(seam_ast, member); found {
				append(&enums, decl)
				continue
			}
			// A field default written as a sibling-module const must fold against the
			// SEAM module's `let` table here — the entrypoint emit only has the entry
			// module's lets, so an imported default left unfolded would reach
			// encode_literal as a bare Name and emit an empty `=` the runtime drops
			// (the imported half of the same empty-default defect). Enums carry no
			// field defaults.
			if decl, found := find_data(seam_ast, member); found {
				decl.fields = fold_field_decls(decl.fields, seam_ast)
				append(&datas, decl)
				continue
			}
			if decl, found := find_signal(seam_ast, member); found {
				decl.fields = fold_field_decls(decl.fields, seam_ast)
				append(&signals, decl)
				continue
			}
			if decl, found := schema_thing(seam_ast, member); found {
				decl.fields = fold_field_decls(decl.fields, seam_ast)
				append(&things, decl)
			}
		}
	}
	return Imported_Decls {
		enums   = enums[:],
		datas   = datas[:],
		signals = signals[:],
		things  = things[:],
	}
}

// find_enum finds a top-level enum by name in a module's AST — the declaration
// carry's lookup, walked by index (never a map, the determinism tripwire).
find_enum :: proc(ast: Ast, name: string) -> (decl: Enum_Node, found: bool) {
	for candidate in ast.enums {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Enum_Node{}, false
}

// find_data finds a top-level data declaration by name in a module's AST —
// the declaration carry's lookup, walked by index.
find_data :: proc(ast: Ast, name: string) -> (decl: Data_Node, found: bool) {
	for candidate in ast.datas {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Data_Node{}, false
}

// find_signal finds a top-level signal by name in a module's AST — the
// declaration carry's lookup, walked by index.
find_signal :: proc(ast: Ast, name: string) -> (decl: Signal_Node, found: bool) {
	for candidate in ast.signals {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Signal_Node{}, false
}
