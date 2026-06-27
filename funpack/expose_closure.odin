package funpack

Expose_Closure_Verdict :: struct {
	declaration: string,
	type_name:   string,
	line:        int,
	violation:   bool,
}

check_expose_closure :: proc(ast: Ast, bindings: Bindings, index: Module_Index, site: ^Type_Diag_Site = nil) -> Type_Error {
	verdict := expose_closure_verdict(ast, bindings, index)
	if verdict.violation {
		stamp_decl(site, verdict.declaration, verdict.line)
		return .Expose_Closure_Violation
	}
	return .None
}

expose_closure_verdict :: proc(ast: Ast, bindings: Bindings, index: Module_Index) -> Expose_Closure_Verdict {
	local := local_type_exposure(ast)
	for ref in ast.decls {
		switch ref.kind {
		case .Data:
			decl := ast.datas[ref.index]
			if decl.exposed {
				if name, open := fields_unexposed_ref(decl.fields, local, bindings, index); open {
					return Expose_Closure_Verdict{declaration = decl.name, type_name = name, line = decl.line, violation = true}
				}
			}
		case .Thing:
			decl := ast.things[ref.index]
			if decl.exposed {
				if name, open := fields_unexposed_ref(decl.fields, local, bindings, index); open {
					return Expose_Closure_Verdict{declaration = decl.name, type_name = name, line = decl.line, violation = true}
				}
			}
		case .Signal:
			decl := ast.signals[ref.index]
			if decl.exposed {
				if name, open := fields_unexposed_ref(decl.fields, local, bindings, index); open {
					return Expose_Closure_Verdict{declaration = decl.name, type_name = name, line = decl.line, violation = true}
				}
			}
		case .Enum:
			decl := ast.enums[ref.index]
			if decl.exposed {
				if name, open := variants_unexposed_ref(decl.variants, local, bindings, index); open {
					return Expose_Closure_Verdict{declaration = decl.name, type_name = name, line = decl.line, violation = true}
				}
			}
		case .Fn:
			decl := ast.fns[ref.index]
			if decl.exposed {
				if name, open := signature_unexposed_ref(decl.params, decl.return_type, local, bindings, index); open {
					return Expose_Closure_Verdict{declaration = decl.name, type_name = name, line = decl.line, violation = true}
				}
			}
		case .Query:
			decl := ast.queries[ref.index]
			if decl.exposed {
				if name, open := signature_unexposed_ref(decl.params, decl.return_type, local, bindings, index); open {
					return Expose_Closure_Verdict{declaration = decl.name, type_name = name, line = decl.line, violation = true}
				}
			}
		case .Let:
			decl := ast.lets[ref.index]
			if decl.exposed {
				if name, open := type_ref_unexposed(decl.type, local, bindings, index); open {
					return Expose_Closure_Verdict{declaration = decl.name, type_name = name, line = decl.line, violation = true}
				}
			}
		case .Behavior, .Pipeline, .Test:
		case .Extern_Type:
		}
	}
	return Expose_Closure_Verdict{}
}

local_type_exposure :: proc(ast: Ast) -> map[string]bool {
	exposure := make(map[string]bool, context.temp_allocator)
	for decl in ast.datas {
		exposure[decl.name] = decl.exposed
	}
	for decl in ast.enums {
		exposure[decl.name] = decl.exposed
	}
	for decl in ast.things {
		exposure[decl.name] = decl.exposed
	}
	for decl in ast.signals {
		exposure[decl.name] = decl.exposed
	}
	for decl in ast.extern_types {
		exposure[decl.name] = decl.exposed
	}
	return exposure
}

signature_unexposed_ref :: proc(
	params: []Param_Decl,
	return_type: Type_Ref,
	local: map[string]bool,
	bindings: Bindings,
	index: Module_Index,
) -> (
	type_name: string,
	open: bool,
) {
	for param in params {
		if name, found := type_ref_unexposed(param.type, local, bindings, index); found {
			return name, true
		}
	}
	return type_ref_unexposed(return_type, local, bindings, index)
}

fields_unexposed_ref :: proc(
	fields: []Field_Decl,
	local: map[string]bool,
	bindings: Bindings,
	index: Module_Index,
) -> (
	type_name: string,
	open: bool,
) {
	for field in fields {
		if name, found := type_ref_unexposed(field.type, local, bindings, index); found {
			return name, true
		}
	}
	return "", false
}

variants_unexposed_ref :: proc(
	variants: []Variant_Decl,
	local: map[string]bool,
	bindings: Bindings,
	index: Module_Index,
) -> (
	type_name: string,
	open: bool,
) {
	for variant in variants {
		for element in variant.tuple {
			if name, found := type_ref_unexposed(element, local, bindings, index); found {
				return name, true
			}
		}
		if name, found := fields_unexposed_ref(variant.fields, local, bindings, index); found {
			return name, true
		}
	}
	return "", false
}

type_ref_unexposed :: proc(
	ref: Type_Ref,
	local: map[string]bool,
	bindings: Bindings,
	index: Module_Index,
) -> (
	type_name: string,
	open: bool,
) {
	if ref.name != "" && ref.name != TYPE_REF_LIST_HEAD && ref.name != TYPE_REF_TUPLE_HEAD && ref.name != TYPE_REF_FN_HEAD {
		if name_unexposed_user_type(ref.name, local, bindings, index) {
			return ref.name, true
		}
	}
	for arg in ref.args {
		if name, found := type_ref_unexposed(arg, local, bindings, index); found {
			return name, true
		}
	}
	return "", false
}

name_unexposed_user_type :: proc(name: string, local: map[string]bool, bindings: Bindings, index: Module_Index) -> bool {
	if exposed, declared := local[name]; declared {
		return !exposed
	}
	binding, bound := bindings.names[name]
	if !bound || binding.kind != .Type_Name {
		return false
	}
	entry, has_entry := module_index_lookup(index, binding.module)
	if !has_entry {
		return false
	}
	export, exported := module_export_lookup(entry, name)
	if !exported || export.kind != .Type {
		return false
	}
	return !export.exposed
}
