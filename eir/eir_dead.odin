package eir

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

Dead_Decl :: struct {
	path:    string,
	is_test: bool,
	line:    int,
	col:     int,
	name:    string,
	kind:    string,
}

find_dead_decls :: proc(result: Load_Result, allocator := context.allocator) -> []Dead_Decl {
	out := make([dynamic]Dead_Decl, 0, 16, allocator)
	for loaded in result.files {
		if loaded.file == nil {
			continue
		}

		counts := tally_idents(loaded.file, context.temp_allocator)

		for decl in loaded.file.decls {
			vd, ok := decl.derived.(^ast.Value_Decl)
			if !ok || !decl_is_file_private(vd) {
				continue
			}
			kind := decl_kind(vd)
			for nm in vd.names {
				id, id_ok := nm.derived.(^ast.Ident)
				if !id_ok || id.name == "_" {
					continue
				}
				if counts[id.name] <= 1 {
					append(
						&out,
						Dead_Decl {
							path = loaded.path,
							is_test = loaded.is_test,
							line = decl.pos.line,
							col = decl.pos.column,
							name = id.name,
							kind = kind,
						},
					)
				}
			}
		}
	}

	slice.sort_by(out[:], dead_less)
	return out[:]
}

@(private = "file")
tally_idents :: proc(file: ^ast.File, allocator := context.allocator) -> map[string]int {
	names := make([dynamic]string, 0, 256, context.temp_allocator)
	v := ast.Visitor {
		visit = tally_visit,
		data  = &names,
	}
	for decl in file.decls {
		ast.walk(&v, decl)
	}

	counts := make(map[string]int, len(names), allocator)
	for name in names {
		counts[name] += 1
	}
	return counts
}

@(private = "file")
tally_visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if visitor == nil || node == nil {
		return visitor
	}
	if id, ok := node.derived.(^ast.Ident); ok {
		names := (^[dynamic]string)(visitor.data)
		append(names, id.name)
	}
	return visitor
}

@(private = "file")
decl_is_file_private :: proc(vd: ^ast.Value_Decl) -> bool {
	for attr in vd.attributes {
		for elem in attr.elems {
			fv, ok := elem.derived.(^ast.Field_Value)
			if !ok {
				continue
			}
			id, id_ok := fv.field.derived.(^ast.Ident)
			if !id_ok || id.name != "private" {
				continue
			}
			lit, lit_ok := fv.value.derived.(^ast.Basic_Lit)
			if lit_ok && strings.trim(lit.tok.text, "\"`") == "file" {
				return true
			}
		}
	}
	return false
}

@(private = "file")
decl_kind :: proc(vd: ^ast.Value_Decl) -> string {
	if len(vd.values) > 0 {
		#partial switch _ in vd.values[0].derived {
		case ^ast.Proc_Lit:
			return "proc"
		case ^ast.Struct_Type, ^ast.Enum_Type, ^ast.Union_Type, ^ast.Bit_Field_Type, ^ast.Proc_Type:
			return "type"
		}
	}
	if vd.is_mutable {
		return "var"
	}
	return "const"
}

@(private = "file")
dead_less :: proc(a, b: Dead_Decl) -> bool {
	if a.path != b.path {
		return a.path < b.path
	}
	if a.line != b.line {
		return a.line < b.line
	}
	return a.name < b.name
}

dead_diagnostics :: proc(decls: []Dead_Decl, allocator := context.allocator) -> []Diagnostic {
	out := make([]Diagnostic, len(decls), allocator)
	for d, i in decls {
		out[i] = Diagnostic {
			file     = d.path,
			line     = d.line,
			col      = d.col,
			severity = .Warning,
			rule     = "dead",
			message  = fmt.aprintf(
				"dead file-private %s '%s' never referenced",
				d.kind,
				d.name,
				allocator = allocator,
			),
			related  = nil,
		}
	}
	return out
}
