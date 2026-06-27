package funpack

import "core:reflect"
import "core:slice"
import "core:strings"

Warden_Find_Query :: struct {
	name: string,
	kind: string,
	gtag: string,
}

warden_find_name_predicate :: proc(decl: Decl_Record, needle: string) -> bool {
	return strings.contains(decl.qualified_name, needle)
}

warden_find_kind_predicate :: proc(decl: Decl_Record, needle: string) -> bool {
	kind, known := reflect.enum_from_name(Index_Decl_Kind, needle)
	return known && decl.kind == kind
}

warden_find_gtag_predicate :: proc(decl: Decl_Record, needle: string) -> bool {
	return slice.contains(decl.gtags, needle)
}

warden_find_filters :: proc(query: Warden_Find_Query, allocator := context.allocator) -> []Warden_Decl_Filter {
	filters := make([dynamic]Warden_Decl_Filter, 0, 3, allocator)
	if query.name != "" {
		append(&filters, Warden_Decl_Filter{test = warden_find_name_predicate, needle = query.name})
	}
	if query.kind != "" {
		append(&filters, Warden_Decl_Filter{test = warden_find_kind_predicate, needle = query.kind})
	}
	if query.gtag != "" {
		append(&filters, Warden_Decl_Filter{test = warden_find_gtag_predicate, needle = query.gtag})
	}
	return filters[:]
}

warden_find_output :: proc(index: Warden_Index, query: Warden_Find_Query, allocator := context.allocator) -> string {
	if query == (Warden_Find_Query{}) {
		return ""
	}
	return warden_project_decls_all(index.decls, warden_find_filters(query, context.temp_allocator), allocator)
}
