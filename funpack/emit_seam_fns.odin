// The §17 cross-module SEAM-FN CARRY: the emitter side that makes a multi-module
// game's [functions] section self-contained. The entrypoint module (krognid's
// `stroll`) imports fns from a sibling USER module — the baked rig seam
// (`import krognid.{krognid_skeleton, krognid_parts}`) — and calls them in a
// behavior body (the Rigged draw: `Draw3::Rigged{ skeleton: krognid_skeleton(),
// parts: krognid_parts(), … }`). emit_functions walks the ENTRYPOINT AST alone, so
// those seam bodies would be absent and the runtime's bare-name program_function
// lookup would return nil for the call. This file collects the imported seam fns —
// signature + body — into Function_Records the emitter appends to [functions],
// each keyed to its OWN seam module's span, so the artifact carries the whole
// executable program with no funpack source on the runtime's path (spec §29).
//
// PURITY (spec §09, §29): the carry is a pure function of the entrypoint AST and
// the sibling-module ASTs. The walk is import-declaration order then member order
// then source fn order — never a map iteration — so the carried records land in a
// fixed order and two emissions are byte-identical. The module_asts map is read by
// key (a single lookup per import), never iterated.
package funpack

// collect_imported_fn_records collects the §17 cross-module fn AND const records
// the entrypoint module references — the fns and module-level `let` constants it
// imports by member name from a sibling USER module whose AST is in module_asts.
// For each import whose leading segment names a present sibling module, every
// imported member that resolves to a (non-extern) top-level fn is carried as a
// Function_Record, and every member that resolves to a module-level `let` is
// carried as a `const` record (schema v15 — the level seam's `terrain:
// TilemapHandle` const a behavior body reads by bare name; without the carry the
// runtime's bare-name lookup would return nil). Each record bears the SEAM
// module's name in its span, so emit_functions appends a self-contained record
// the runtime resolves by bare name. The result is in import-declaration order,
// then the import's brace-group MEMBER order within each import (deterministic —
// both are source-order slices, and the module_asts map is read by key, never
// iterated).
// A nil/empty module_asts (the single-source path) carries nothing — pong/snake/
// hunt/yard emit byte-for-byte as before. An imported member that is a TYPE rides
// the v15 declaration carry (collect_imported_decls); an extern fn carries no
// interpretable body, so it is never a [functions] record (the level-seam spawns
// extern folds into [setup] instead — emit_level_setup.odin).
collect_imported_fn_records :: proc(entry_ast: Ast, module_asts: map[string]Ast) -> []Function_Record {
	if len(module_asts) == 0 {
		return nil
	}
	records := make([dynamic]Function_Record, 0, 4, context.temp_allocator)
	for import_node in entry_ast.imports {
		seam_module, members, is_user := imported_user_module(import_node, module_asts)
		if !is_user {
			continue
		}
		seam_ast := module_asts[seam_module]
		for member in members {
			if fn, found := find_fn(seam_ast, member); found {
				if fn.is_extern {
					continue
				}
				append(&records, Function_Record {
					name         = fn.name,
					kind         = function_kind(fn.name),
					params       = fn.params,
					return_type  = fn.return_type,
					body         = fn.body,
					line         = fn.line,
					module       = seam_module,
					holed        = fn.holed,
					has_fallback = fn.has_fallback,
					fallback     = fn.fallback,
				})
				continue
			}
			if decl, found := find_let(seam_ast, member); found {
				// An imported module-level `let` carries as the same `function NAME
				// const` record an own const emits (docs/artifact-format.md §9): no
				// params, the initializer as a single `return` subtree, the seam
				// module's span.
				append(&records, Function_Record {
					name        = decl.name,
					kind        = "const",
					params      = nil,
					return_type = decl.type,
					body        = const_body(decl),
					line        = decl.line,
					module      = seam_module,
				})
			}
		}
	}
	return records[:]
}

// imported_user_module reports whether an import names a sibling USER module whose
// AST is in module_asts, returning that module's §15 name and the brace-group
// members the import binds. A user-module import is a single-segment path with a
// brace group (`import krognid.{krognid_skeleton, krognid_parts}` parses to
// segments ["krognid"], members [...]); a STDLIB import (`engine.math.{…}`,
// segments ["engine","math"]) or a whole-module handle (no members) is not a
// member-carrying user import the seam carry reads. The leading segment must be a
// key in module_asts — an `engine.*` path never matches a user module, so the
// stdlib import is left to the resolver.
imported_user_module :: proc(
	import_node: Import_Node,
	module_asts: map[string]Ast,
) -> (module: string, members: []string, ok: bool) {
	if len(import_node.segments) != 1 || len(import_node.members) == 0 {
		return "", nil, false
	}
	candidate := import_node.segments[0]
	if _, present := module_asts[candidate]; !present {
		return "", nil, false
	}
	return candidate, import_node.members, true
}

// find_fn finds a top-level fn by name in a module's AST — the seam carry's lookup
// of an imported member against its owning module's fn declarations. found = false
// when the name is not a top-level fn (it may be a type or a const), so the caller
// falls through to the const/type carries.
find_fn :: proc(ast: Ast, name: string) -> (fn: Fn_Node, found: bool) {
	for candidate in ast.fns {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Fn_Node{}, false
}

// find_let finds a module-level `let` by name in a module's AST — the v15 seam
// carry's lookup of an imported member against its owning module's constants.
// found = false when the name is not a module-level let (the caller leaves a type
// member to the declaration carry).
find_let :: proc(ast: Ast, name: string) -> (decl: Let_Decl_Node, found: bool) {
	for candidate in ast.lets {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Let_Decl_Node{}, false
}
