// The DEAD lint: report file-private package-level declarations that nothing in their
// file references — definitively dead code. A `@(private="file")` declaration is reachable
// ONLY from within its own file, so if its name appears nowhere in that file beyond its
// own declaration, no reachable caller exists and it can be deleted. That makes the
// analysis SOUND on a single file with no cross-file or whole-program graph: the visibility
// rule, not a call-graph approximation, is what guarantees the verdict. Odin's own `-vet`
// flags unused locals and imports but NOT an unused file-private package-level proc/type/
// const, so this closes a real gap the manual-dedup program keeps hitting.
//
// References are counted by walking the file with core:odin/ast's own visitor (ast.walk)
// and tallying every Ident by name — the dead lint reuses the stdlib traversal rather than
// re-deriving one (which would duplicate the clone engine's walk and trip the dup gate).
// A name's tally always includes its single declaration occurrence, so a tally of one means
// "declared, never used". The count is deliberately OVER-inclusive — a struct-field selector
// `x.foo` or a same-named local both tally `foo` — because a dead lint must err toward
// silence: a missed use would falsely condemn live code, so every ambiguity counts as a use
// and the lint under-reports rather than lies. Transitive death (a private proc referenced
// only by another dead private proc) is therefore NOT chased — each pass reports the
// directly-unreferenced, and deleting them exposes the next layer for the following run.
package eir

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

// Dead_Decl is one unreferenced file-private declaration: where it sits (line and start
// column — the `file:line:col` point the diagnostic surface reports it by), its test tag (so
// a consumer can scope production vs test dead code), its name, and a coarse kind
// (proc/type/const/var) for the report label.
Dead_Decl :: struct {
	path:    string,
	is_test: bool,
	line:    int,
	col:     int,
	name:    string,
	kind:    string,
}

// find_dead_decls runs the dead lint over a Load_Result and returns every unreferenced
// file-private declaration in a deterministic order (by path, then line, then name). For
// each file it tallies every Ident by name, then reports each file-private top-level name
// whose tally is one (the declaration itself, no use). The result borrows the loader's path
// strings; keep the loader alive while reading it.
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
				// The declaration contributes exactly one tally of its own name; a tally
				// of one therefore means the name is never used anywhere in the file.
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

// tally_idents walks one file with the stdlib visitor and returns a name -> occurrence-count
// map over every Ident in the file (declaration names, uses, selector fields, type
// references — all of them). data carries the accumulator into the visit callback (the
// visitor has no closure), and the callback tallies each Ident it reaches.
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

// tally_visit is the ast.walk callback: it appends every Ident's name to the accumulator
// the visitor's data points at and returns the visitor to keep descending (nil would prune
// the subtree). The nil node walk passes at each subtree's end carries no Ident, so it is
// ignored.
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

// decl_is_file_private reports whether a value declaration carries `@(private="file")`. It
// matches the parenthesized key=value form (a `private` field whose string value is `file`),
// the canonical spelling of file scope; any other attribute spelling is treated as not
// file-private, so the lint under-claims rather than over-claims visibility.
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

// decl_kind classifies a declaration for the report label: proc (a proc literal), type (a
// struct/enum/union/bit-field/proc type), const (an immutable `::` binding), or var (a
// mutable top-level `:=`/`: T`). The classification is for the human label only; the dead
// verdict never depends on it.
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

// dead_less is the total order on dead declarations: by path, then line, then name. Two
// distinct declarations cannot tie on all three, so it is a total order — the determinism
// the byte-stable JSON needs.
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

// dead_diagnostics projects the dead declarations onto the shared diagnostic surface in their
// reported order (by path, then line): one Warning per declaration, a point finding with no
// related sites. The message names the kind and the declaration so the operator knows what to
// delete. The diagnostics borrow the loader's path strings; keep the loader alive while
// reading them. Allocated in `allocator`.
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
