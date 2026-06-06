// The project-wide module index and the user-module import arm that rides on
// it. The frontend was single-source: resolve_imports validated every import
// against STDLIB_SURFACE alone (surface.odin), so an `import arena_world.{Player}`
// referencing a SIBLING user module returned .Unknown_Module. A multi-module
// project (the arena example: arena_game.fun imports both arena_world and the
// generated arena seam) needs a project-wide name index built over EVERY source
// before per-module resolution, so a member-group or dotted import whose leading
// segments name a user module resolves its members against that module's
// exported names.
//
// The index is a closed two-position view of each module's surface (spec §15:
// a module's name is its §15 path-derived location, and its exports are its
// top-level declarations): the type-position names (data/enum/thing/singleton/
// signal) and the term-position names (top-level fn). It is built once from
// []Source and threaded through the resolver alongside STDLIB_SURFACE; an
// unknown user module, an unknown member of a known user module, and a name
// colliding with an in-scope import all stay compile errors (spec §02
// one-name-one-meaning), exactly as the stdlib arm enforces them.
//
// Determinism: every module entry stores its exports as ORDERED slices, walked
// by index — no map is ever iterated (the determinism tripwire), mirroring
// STDLIB_SURFACE and Bindings. The module list is keyed by name and looked up
// by a linear walk, the same shape surface_module uses over the partition table.
package funpack

import "core:os"

// Module_Export_Kind is the closed two-position view the index records for
// each exported name: a type-position name (a data/enum/thing/singleton/signal
// declaration) or a term-position name (a top-level fn). It maps 1:1 onto the
// Decl_Kind a resolved Binding carries — a type export binds as .Type_Name, a
// term export as .Func — so a user-module import populates Bindings identically
// to a stdlib import.
Module_Export_Kind :: enum {
	Type, // a data/enum/thing/singleton/signal declaration — a type-position name
	Term, // a top-level fn declaration — a term-position name
}

// Module_Export pairs one exported name with its position. The position is read
// when the resolver binds the name, so a cross-module type reference (a field's
// Ref[T] naming a sibling-module type) resolves to a type-position binding while
// a fn reference resolves to a term-position binding. user_kind carries the §06
// declaration form of a .Type export (Thing/Data/Enum/Signal) so a cross-module
// type reference resolves to a nominal User_Type with the right kind; it is
// meaningless (.Thing as a placeholder) for a .Term export.
Module_Export :: struct {
	name:      string,
	kind:      Module_Export_Kind,
	user_kind: User_Kind, // the §06 form of a .Type export; unused for a .Term
}

// Module_Entry is one user module's exported surface: its §15 path-derived
// module name and the ORDERED export list (source order within each kind, type
// exports before term exports). The list is walked by index — never a map — so
// the resolver's verdict is reproducible from the source set alone.
Module_Entry :: struct {
	module:  string,
	exports: []Module_Export,
}

// Module_Index is the project-wide name index: one Module_Entry per user module,
// keyed by module name and looked up by a linear walk (module_index_lookup). It
// is the user-module analogue of STDLIB_SURFACE — the closed table the
// user-module import arm resolves members against. An empty index (the
// single-source case) makes every user-module import a .Unknown_Module reject,
// which is the prior single-source behavior.
Module_Index :: struct {
	modules: []Module_Entry,
}

// Module_Index_Error is closed with one arm per way building the index can fail
// before any module resolves. Read_Failed is a source file the index cannot read
// off disk; Parse_Failed is a source whose bytes the §06/§07 grammar rejects.
// Both fail the whole index build — a project with an unreadable or unparseable
// source has no well-defined name surface, so resolution never proceeds against
// a partial index.
Module_Index_Error :: enum {
	None,
	Read_Failed,
	Parse_Failed,
}

// build_module_index reads every source in the set, lexes and parses each, and
// records its top-level declaration names into the per-module export list. It is
// name-and-position only: no body is typed and no import is resolved — the index
// is the input the resolver consults, built before any per-module resolution.
// The entries preserve the source order of []Source (project.odin sorts paths
// for determinism), so the index is reproducible from the tree alone. A source
// that cannot be read or parsed fails the whole build (Module_Index_Error).
build_module_index :: proc(sources: []Source) -> (index: Module_Index, err: Module_Index_Error) {
	entries := make([dynamic]Module_Entry, 0, len(sources), context.temp_allocator)
	for source in sources {
		source_bytes, read_err := os.read_entire_file_from_path(source.path, context.temp_allocator)
		if read_err != nil {
			return Module_Index{}, .Read_Failed
		}
		ast, parse_err := stage_parse(stage_lex(string(source_bytes)))
		if parse_err != .None {
			return Module_Index{}, .Parse_Failed
		}
		append(&entries, Module_Entry{module = source.module, exports = collect_module_exports(ast)})
	}
	return Module_Index{modules = entries[:]}, .None
}

// build_module_index_from_asts builds the index directly from already-parsed
// (module, Ast) pairs, the unit-test seam that needs no on-disk reads — a
// hand-built stand-in for a not-yet-generated seam module (the arena seam) joins
// the index alongside the real, file-backed sources. It shares collect_module_exports
// with build_module_index, so a stand-in entry carries the identical export shape
// a file-backed entry would.
build_module_index_from_asts :: proc(modules: []string, asts: []Ast) -> Module_Index {
	entries := make([dynamic]Module_Entry, 0, len(asts), context.temp_allocator)
	for ast, i in asts {
		append(&entries, Module_Entry{module = modules[i], exports = collect_module_exports(ast)})
	}
	return Module_Index{modules = entries[:]}
}

// collect_module_exports lifts a parsed module's top-level declarations into its
// ordered export list: every type-position declaration (data/enum/thing/
// singleton/signal) as a .Type export, then every top-level fn as a .Term export.
// A module's whole top-level surface is exported (spec §15: a module has no
// visibility modifier — a declaration's presence at module scope IS its export),
// so the index mirrors resolve_env's own type/term partition. Behaviors and lets
// are NOT exported: a behavior is reached through its own module's pipeline, and
// a module-level let is a private constant — neither is an importable name across
// modules. The order is source order within each kind, type exports first, so
// the list walks deterministically.
collect_module_exports :: proc(ast: Ast) -> []Module_Export {
	exports := make([dynamic]Module_Export, 0, 8, context.temp_allocator)
	for decl in ast.things {
		// `thing` and `singleton` both occupy the .Thing user kind (parser
		// folds them into ast.things, distinguished only by is_singleton).
		append(&exports, Module_Export{name = decl.name, kind = .Type, user_kind = .Thing})
	}
	for decl in ast.datas {
		append(&exports, Module_Export{name = decl.name, kind = .Type, user_kind = .Data})
	}
	for decl in ast.signals {
		append(&exports, Module_Export{name = decl.name, kind = .Type, user_kind = .Signal})
	}
	for decl in ast.enums {
		append(&exports, Module_Export{name = decl.name, kind = .Type, user_kind = .Enum})
	}
	for decl in ast.fns {
		append(&exports, Module_Export{name = decl.name, kind = .Term})
	}
	return exports[:]
}

// module_index_lookup finds a module entry by name, walked by index like every
// table here — never a map. The user-module import arm calls it after the stdlib
// arm misses, so a path naming neither a stdlib partition nor a user module is
// the .Unknown_Module reject.
module_index_lookup :: proc(index: Module_Index, module: string) -> (entry: Module_Entry, found: bool) {
	for candidate in index.modules {
		if candidate.module == module {
			return candidate, true
		}
	}
	return Module_Entry{}, false
}

// module_export_lookup finds one exported name within a module entry, walked by
// index. A name the module does not export is the .Unknown_Member reject — the
// user-module analogue of surface_lookup over a stdlib partition.
module_export_lookup :: proc(entry: Module_Entry, name: string) -> (export: Module_Export, found: bool) {
	for candidate in entry.exports {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Module_Export{}, false
}

// module_export_binding maps an export's position to the Binding the resolver
// records: the binding's module is the OWNING user module, so a cross-module
// reference carries the source of its meaning (spec §02 one-name-one-meaning),
// and the Decl_Kind mirrors the export's position — a type export binds as
// .Type_Name, a term export as .Func — so a user-module import populates
// Bindings identically to a stdlib import.
module_export_binding :: proc(module: string, export: Module_Export) -> Binding {
	kind := Decl_Kind.Type_Name if export.kind == .Type else Decl_Kind.Func
	return Binding{module = module, kind = kind}
}

// index_user_type resolves a name that an import bound to a sibling user module
// into the checker's nominal User_Type, recovering the export's §06 kind from
// the owning module's entry. The resolver calls it for a field/param Type_Ref
// whose name is in scope as a user-module type binding (a `gate: Ref[Switch]`
// where Switch was imported from arena_world, or a `data Arena` field typed by
// the seam) — the cross-module type reference resolves to the same nominal handle
// the owning module's own resolve_env would build for it. found = false when the
// name is not an in-scope user-module type binding (a stdlib import, a prelude
// name, or an unbound name), leaving the caller's other arms to resolve it.
index_user_type :: proc(index: Module_Index, bindings: Bindings, name: string) -> (type: Type, found: bool) {
	binding, bound := bindings.names[name]
	if !bound || binding.kind != .Type_Name {
		return nil, false
	}
	entry, has_entry := module_index_lookup(index, binding.module)
	if !has_entry {
		return nil, false
	}
	export, exported := module_export_lookup(entry, name)
	if !exported || export.kind != .Type {
		return nil, false
	}
	return user_type_of(name, export.user_kind), true
}

// resolve_user_import resolves one import's members against a known user module's
// export list, binding each into the consuming module's environment. It is the
// user-module sibling of the stdlib arm (surface_resolve + bind_name): a member
// the module exports binds to the owning module; a member it does not export is
// .Unknown_Member; a member whose name already binds to a DIFFERENT in-scope
// import is .Name_Collision (bind_name enforces the §02 rule). The caller has
// already confirmed the module is in the index, so this arm never re-checks
// module existence.
resolve_user_import :: proc(bindings: ^Bindings, entry: Module_Entry, members: []string) -> Type_Error {
	for member in members {
		export, exported := module_export_lookup(entry, member)
		if !exported {
			return .Unknown_Member
		}
		bind_name(bindings, member, module_export_binding(entry.module, export)) or_return
	}
	return .None
}
