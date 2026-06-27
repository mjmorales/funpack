package funpack

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

find_fn :: proc(ast: Ast, name: string) -> (fn: Fn_Node, found: bool) {
	for candidate in ast.fns {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Fn_Node{}, false
}

find_let :: proc(ast: Ast, name: string) -> (decl: Let_Decl_Node, found: bool) {
	for candidate in ast.lets {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Let_Decl_Node{}, false
}
