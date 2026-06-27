package funpack

import "core:slice"
import "core:strings"

WARDEN_DEBT_GTAG :: "debt"

Warden_Decl_Predicate :: #type proc(decl: Decl_Record, needle: string) -> bool

Warden_Decl_Filter :: struct {
	test:   Warden_Decl_Predicate,
	needle: string,
}

warden_project_decls :: proc(
	decls: []Decl_Record,
	predicate: Warden_Decl_Predicate,
	needle: string,
	allocator := context.allocator,
) -> string {
	filters := []Warden_Decl_Filter{{test = predicate, needle = needle}}
	return warden_project_decls_all(decls, filters, allocator)
}

warden_project_decls_all :: proc(
	decls: []Decl_Record,
	filters: []Warden_Decl_Filter,
	allocator := context.allocator,
) -> string {
	lines := make([dynamic]string, 0, len(decls), context.temp_allocator)
	match_loop: for decl in decls {
		for filter in filters {
			if !filter.test(decl, filter.needle) {
				continue match_loop
			}
		}
		append(&lines, emit_decl_record(decl, context.temp_allocator))
	}
	return strings.concatenate(lines[:], allocator)
}

warden_holes_predicate :: proc(decl: Decl_Record, needle: string) -> bool {
	_ = needle
	return decl.stub
}

warden_probes_predicate :: proc(decl: Decl_Record, needle: string) -> bool {
	_ = needle
	return len(decl.debug) > 0
}

warden_debt_predicate :: proc(decl: Decl_Record, needle: string) -> bool {
	_ = needle
	return decl.todo || slice.contains(decl.gtags, WARDEN_DEBT_GTAG)
}
