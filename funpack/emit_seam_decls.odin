package funpack

Imported_Decls :: struct {
	enums:   []Enum_Node,
	datas:   []Data_Node,
	signals: []Signal_Node,
	things:  []Thing_Node,
}

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
			if decl, found := flvl_schema_thing(seam_ast, member); found {
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

find_enum :: proc(ast: Ast, name: string) -> (decl: Enum_Node, found: bool) {
	for candidate in ast.enums {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Enum_Node{}, false
}

find_data :: proc(ast: Ast, name: string) -> (decl: Data_Node, found: bool) {
	for candidate in ast.datas {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Data_Node{}, false
}

find_signal :: proc(ast: Ast, name: string) -> (decl: Signal_Node, found: bool) {
	for candidate in ast.signals {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Signal_Node{}, false
}
