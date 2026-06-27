package funpack

import "core:os"

Module_Export_Kind :: enum {
	Type,
	Term,
	Const,
}

Module_Export :: struct {
	name:      string,
	kind:      Module_Export_Kind,
	user_kind: User_Kind,
	signature: ^Func_Type,
	let_type:  Type,
	exposed:   bool,
}

Module_Record_Schema :: struct {
	name:   string,
	schema: Record_Schema,
}

Module_Enum_Schema :: struct {
	name:   string,
	schema: Enum_Schema,
}

Module_Entry :: struct {
	module:         string,
	package_root:   string,
	exports:        []Module_Export,
	record_schemas: []Module_Record_Schema,
	enum_schemas:   []Module_Enum_Schema,
}

Module_Index :: struct {
	modules: []Module_Entry,
}

Module_Index_Error :: enum {
	None,
	Read_Failed,
	Parse_Failed,
}

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

build_module_index_from_asts :: proc(modules: []string, asts: []Ast, package_roots: []string = nil) -> Module_Index {
	entries := make([dynamic]Module_Entry, 0, len(asts), context.temp_allocator)
	for ast, i in asts {
		append(&entries, Module_Entry {
			module       = modules[i],
			package_root = package_roots[i] if package_roots != nil else "",
			exports      = collect_module_exports(ast),
		})
	}
	return Module_Index{modules = entries[:]}
}

build_module_index_typed :: proc(modules: []string, asts: []Ast, package_roots: []string = nil) -> Module_Index {
	name_index := build_module_index_from_asts(modules, asts, package_roots)
	entries := make([dynamic]Module_Entry, 0, len(asts), context.temp_allocator)
	for ast, i in asts {
		exports := collect_module_exports(ast)
		root := package_roots[i] if package_roots != nil else ""
		record_schemas, enum_schemas := fill_export_types(&exports, ast, name_index, root)
		append(&entries, Module_Entry {
			module         = modules[i],
			package_root   = package_roots[i] if package_roots != nil else "",
			exports        = exports,
			record_schemas = record_schemas,
			enum_schemas   = enum_schemas,
		})
	}
	return Module_Index{modules = entries[:]}
}

fill_export_types :: proc(
	exports: ^[]Module_Export,
	ast: Ast,
	name_index: Module_Index,
	importer_root := "",
) -> (
	record_schemas: []Module_Record_Schema,
	enum_schemas: []Module_Enum_Schema,
) {
	bindings, bind_err := resolve_imports_indexed(ast, name_index, importer_root)
	if bind_err != .None {
		return nil, nil
	}
	env, env_err := resolve_env(ast, bindings, name_index)
	if env_err != .None {
		return nil, nil
	}
	for &export in exports {
		#partial switch export.kind {
		case .Term:
			if term, found := env_term_name(env, export.name); found {
				export.signature = term.signature
			}
		case .Const:
			if term, found := env_term_name(env, export.name); found {
				export.let_type = term.type
			}
		}
	}
	records := make([dynamic]Module_Record_Schema, 0, 8, context.temp_allocator)
	enums := make([dynamic]Module_Enum_Schema, 0, 8, context.temp_allocator)
	for &export in exports {
		if export.kind != .Type {
			continue
		}
		if record, declared := env.records[export.name]; declared {
			append(&records, Module_Record_Schema{name = export.name, schema = record})
		}
		if enum_schema, declared := env.enums[export.name]; declared {
			append(&enums, Module_Enum_Schema{name = export.name, schema = enum_schema})
		}
	}
	return records[:], enums[:]
}

module_call_signature :: proc(index: Module_Index, bindings: Bindings, name: string) -> (signature: ^Func_Type, found: bool) {
	binding, bound := bindings.names[name]
	if !bound || binding.kind != .Func {
		return nil, false
	}
	entry, has_entry := module_index_lookup(index, binding.module)
	if !has_entry {
		return nil, false
	}
	export, exported := module_export_lookup(entry, name)
	if !exported || export.kind != .Term || export.signature == nil {
		return nil, false
	}
	return export.signature, true
}

module_member_const_type :: proc(index: Module_Index, bindings: Bindings, name: string) -> (type: Type, found: bool) {
	binding, bound := bindings.names[name]
	if !bound || binding.kind != .Value {
		return nil, false
	}
	entry, has_entry := module_index_lookup(index, binding.module)
	if !has_entry {
		return nil, false
	}
	export, exported := module_export_lookup(entry, name)
	if !exported || export.kind != .Const {
		return nil, false
	}
	return export.let_type, true
}

module_const_type :: proc(index: Module_Index, bindings: Bindings, handle: string, member: string) -> (type: Type, found: bool) {
	binding, bound := bindings.names[handle]
	if !bound || binding.kind != .Module {
		return nil, false
	}
	entry, has_entry := module_index_lookup(index, binding.module)
	if !has_entry {
		return nil, false
	}
	export, exported := module_export_lookup(entry, member)
	if !exported || export.kind != .Const {
		return nil, false
	}
	return export.let_type, true
}

module_member_kind :: proc(index: Module_Index, bindings: Bindings, handle: string, member: string, importer_root := "") -> (kind: Module_Export_Kind, exported: bool, handle_known: bool, importable: bool) {
	binding, bound := bindings.names[handle]
	if !bound || binding.kind != .Module {
		return {}, false, false, false
	}
	entry, has_entry := module_index_lookup(index, binding.module)
	if !has_entry {
		return {}, false, false, false
	}
	export, found := module_export_lookup(entry, member)
	if !found {
		return {}, false, true, false
	}
	return export.kind, true, true, module_export_importable(entry, export, importer_root)
}

module_record_schema :: proc(index: Module_Index, bindings: Bindings, name: string) -> (schema: Record_Schema, found: bool) {
	binding, bound := bindings.names[name]
	if !bound || binding.kind != .Type_Name {
		return Record_Schema{}, false
	}
	entry, has_entry := module_index_lookup(index, binding.module)
	if !has_entry {
		return Record_Schema{}, false
	}
	for candidate in entry.record_schemas {
		if candidate.name == name {
			return candidate.schema, true
		}
	}
	return Record_Schema{}, false
}

module_enum_schema :: proc(index: Module_Index, bindings: Bindings, name: string) -> (schema: Enum_Schema, found: bool) {
	binding, bound := bindings.names[name]
	if !bound || binding.kind != .Type_Name {
		return Enum_Schema{}, false
	}
	entry, has_entry := module_index_lookup(index, binding.module)
	if !has_entry {
		return Enum_Schema{}, false
	}
	for candidate in entry.enum_schemas {
		if candidate.name == name {
			return candidate.schema, true
		}
	}
	return Enum_Schema{}, false
}

collect_module_exports :: proc(ast: Ast) -> []Module_Export {
	exports := make([dynamic]Module_Export, 0, 8, context.temp_allocator)
	for decl in ast.things {
		append(&exports, Module_Export{name = decl.name, kind = .Type, user_kind = .Thing, exposed = decl.exposed})
	}
	for decl in ast.datas {
		append(&exports, Module_Export{name = decl.name, kind = .Type, user_kind = .Data, exposed = decl.exposed})
	}
	for decl in ast.signals {
		append(&exports, Module_Export{name = decl.name, kind = .Type, user_kind = .Signal, exposed = decl.exposed})
	}
	for decl in ast.enums {
		append(&exports, Module_Export{name = decl.name, kind = .Type, user_kind = .Enum, exposed = decl.exposed})
	}
	for decl in ast.fns {
		append(&exports, Module_Export{name = decl.name, kind = .Term, exposed = decl.exposed})
	}
	for decl in ast.lets {
		append(&exports, Module_Export{name = decl.name, kind = .Const, exposed = decl.exposed})
	}
	return exports[:]
}

module_index_lookup :: proc(index: Module_Index, module: string) -> (entry: Module_Entry, found: bool) {
	for candidate in index.modules {
		if candidate.module == module {
			return candidate, true
		}
	}
	return Module_Entry{}, false
}

module_export_lookup :: proc(entry: Module_Entry, name: string) -> (export: Module_Export, found: bool) {
	for candidate in entry.exports {
		if candidate.name == name {
			return candidate, true
		}
	}
	return Module_Export{}, false
}

module_export_importable :: proc(entry: Module_Entry, export: Module_Export, importer_root := "") -> bool {
	return entry.package_root == importer_root || export.exposed
}

module_export_binding :: proc(module: string, export: Module_Export) -> Binding {
	kind: Decl_Kind
	switch export.kind {
	case .Type:
		kind = .Type_Name
	case .Term:
		kind = .Func
	case .Const:
		kind = .Value
	}
	return Binding{module = module, kind = kind}
}

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

resolve_user_import :: proc(bindings: ^Bindings, entry: Module_Entry, members: []string, importer_root := "") -> Type_Error {
	for member in members {
		export, exported := module_export_lookup(entry, member)
		if !exported {
			return .Unknown_Member
		}
		if !module_export_importable(entry, export, importer_root) {
			return .Package_Private
		}
		bind_name(bindings, member, module_export_binding(entry.module, export)) or_return
	}
	return .None
}
