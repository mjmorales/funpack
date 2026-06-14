// The `funpack warden find` query (spec §29 §4): the reuse-before-write
// declaration lookup — an agent queries the index for an existing declaration
// BEFORE implementing one (the duplication gate is the post-hoc half of the
// same doctrine). find is a filtered projection over the decoded Decl_Record
// slice riding the shared filter-and-reproject core (warden_project.odin):
// each provided filter becomes one Warden_Decl_Filter and the core
// AND-conjoins them in a single pass, re-emitting every match byte-identical
// to its producer line in the stream's pinned order.
//
// The query shape: `funpack warden find [<name-query>] [--kind <kind>]
// [--gtag <tag>]` — name-query is a case-sensitive SUBSTRING match on
// qualified_name, --kind is an EXACT match against the closed Index_Decl_Kind
// member names (an unknown name is usage exit 2, never a fuzzy match), --gtag
// is exact membership in the record's gtags. At least one filter is required:
// find answers a lookup, it is not the index dump, so the bare command is the
// usage error — adjudicated at parse, before any index read, so it holds in
// any directory. Zero matches exit 0 printing nothing: an empty result means
// "nothing to reuse — write it", a successful answer (§29 §1).
package funpack

import "core:reflect"
import "core:slice"
import "core:strings"

// Warden_Find_Query is the parsed find filter set. "" marks a filter as not
// provided — the CLI rejects an EMPTY filter value as usage before this struct
// is built (cli_funpack.odin: cli_nonempty guards --gtag, cli_validate_index_-
// decl_kind guards --kind, and cli_validate_warden_find rejects an empty
// name-query and the filterless bare command), so the sentinel is unambiguous.
// kind holds the validated Index_Decl_Kind member name verbatim; the flag
// validator already exact-matched it against the closed enum, so downstream
// reads never re-adjudicate.
Warden_Find_Query :: struct {
	name: string, // case-sensitive substring over qualified_name; "" = not provided
	kind: string, // exact Index_Decl_Kind member name; "" = not provided
	gtag: string, // exact gtags membership; "" = not provided
}

// warden_find_name_predicate is the name-query filter: a case-sensitive
// substring match on the record's qualified_name — deterministic, no folding,
// no globbing. needle is the query text.
warden_find_name_predicate :: proc(decl: Decl_Record, needle: string) -> bool {
	return strings.contains(decl.qualified_name, needle)
}

// warden_find_kind_predicate is the --kind filter: the record's kind equals
// the closed Index_Decl_Kind member the needle names exactly. The parse
// already refused an unknown name, so the enum_from_name miss arm here is
// pure defense — a miss matches nothing rather than everything.
warden_find_kind_predicate :: proc(decl: Decl_Record, needle: string) -> bool {
	kind, known := reflect.enum_from_name(Index_Decl_Kind, needle)
	return known && decl.kind == kind
}

// warden_find_gtag_predicate is the --gtag filter: exact membership of the
// needle in the record's authored-order gtags — a linear scan, never a
// substring or prefix match (tag names are registry identities, §14 §4).
warden_find_gtag_predicate :: proc(decl: Decl_Record, needle: string) -> bool {
	return slice.contains(decl.gtags, needle)
}

// warden_find_filters projects the parsed query onto its filter list — one
// Warden_Decl_Filter per provided argument, in the fixed name → kind → gtag
// order. The order is cosmetic (a conjunction commutes); fixing it keeps the
// projection a deterministic function of the query.
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

// warden_find_output renders the find query as its NDJSON byte stream through
// the shared AND-composing core: matching records re-emit byte-identical to
// their producer lines in the stream's pinned order; zero matches render ""
// ("nothing to reuse — write it"). The filterless query never reaches this
// seam from the CLI (the parse gate refused it as usage); the empty-query
// early-out mirrors that gate defensively, rendering nothing rather than
// vacuously dumping every record through the core's zero-filter conjunction.
warden_find_output :: proc(index: Warden_Index, query: Warden_Find_Query, allocator := context.allocator) -> string {
	if query == (Warden_Find_Query{}) {
		return ""
	}
	return warden_project_decls_all(index.decls, warden_find_filters(query, context.temp_allocator), allocator)
}
