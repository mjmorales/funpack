// The warden decl-predicate projection core (spec §29 §1/§4): the shared
// filter-and-reproject seam every per-declaration `funpack warden` query
// rides, plus the two pure predicate commands built directly on it — `holes`
// (the §05 typed-hole report) and `debt` (the @todo + registered `debt` gtag
// review surface).
//
// The core is one pure function over the decoded Decl_Record slice: a single
// forward pass that re-emits each matching record through the producer's own
// emit_decl_record (index_contract.odin), so a projected line is
// BYTE-IDENTICAL to its producer line and the output order is the stream's
// pinned emission order (entrypoint-module-first, gate_units-style —
// read_warden_index decodes positionally and this pass never re-sorts). No
// map iteration reaches the output, no clock is read, and nothing is written
// — the projection answers over the contract, never the AST (§29 §4
// reuse-before-write). An empty match set is a successful projection of zero
// lines, never an error: the warden adjudicates nothing, so the exit contract
// stays {0, 2} with no counted-failure tier.
package funpack

import "core:slice"
import "core:strings"

// WARDEN_DEBT_GTAG is the registered @gtag name the debt query keys on: a
// declaration tagged `debt` in the tags.fcfg registry is debt by authored
// intent (§29 §4 — "leaves debt with no record" is the failure mode this
// surfaces). The name is a contract constant, not a knob: an UNREGISTERED tag
// is already a compile error at the producer (§14 §4), so the projection
// never needs a tag-existence check of its own.
WARDEN_DEBT_GTAG :: "debt"

// Warden_Decl_Predicate is the closed shape of a per-declaration query test:
// a pure record → verdict function over ONE decoded Decl_Record. `needle`
// threads the query's argument for parameterized commands (`warden find
// <name>`); Odin procs do not capture, so the argument rides the call
// explicitly and the nullary predicates (holes, debt) ignore it ("" by
// convention). A predicate reads the record's contract fields only — never
// the filesystem, the clock, or any ambient state — so the projection it
// drives is deterministic (§29 §1).
Warden_Decl_Predicate :: #type proc(decl: Decl_Record, needle: string) -> bool

// Warden_Decl_Filter pairs one predicate with its needle — one test of a
// multi-filter query. The pair exists so AND-composition stays in the shared
// core: a parameterized command (`warden find`) builds one filter per
// provided argument and the core conjoins them in a single pass, instead of
// growing a second filter loop per command.
Warden_Decl_Filter :: struct {
	test:   Warden_Decl_Predicate,
	needle: string,
}

// warden_project_decls is the shared filter-and-reproject core over ONE
// predicate: the single-filter projection of warden_project_decls_all, kept
// as the direct seam the nullary commands (holes, debt) ride.
warden_project_decls :: proc(
	decls: []Decl_Record,
	predicate: Warden_Decl_Predicate,
	needle: string,
	allocator := context.allocator,
) -> string {
	filters := []Warden_Decl_Filter{{test = predicate, needle = needle}}
	return warden_project_decls_all(decls, filters, allocator)
}

// warden_project_decls_all is the shared filter-and-reproject core: one
// forward pass over the decoded decl slice, re-emitting each record EVERY
// filter matches (AND-composition — the conjunction is the core's, so a
// multi-filter command never grows its own pass) as its one NDJSON line via
// emit_decl_record — the producer's own emitter, so the projected bytes
// round-trip the contract byte-identically (the index_read_test re-emit
// identity, applied per match). The output is the matching lines concatenated
// in INPUT order: the slice carries the stream's pinned emission order and a
// filter pass preserves it, so two runs over the same index are
// byte-identical with no re-sort and no map iteration. Zero matches
// concatenate to "" — the empty projection is a success, the caller prints
// nothing and exits 0. Zero FILTERS match every record (a vacuous
// conjunction); the filterless-find usage gate lives at the parse tier, not
// here. Per-line strings are temp-allocated; the joined result lands in
// `allocator` (the emit_index_stream allocation contract).
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

// warden_holes_predicate is `funpack warden holes` (§29 §4): a declaration is
// a hole exactly when its contract `stub` field is true — the §05 §2
// AST-derived typed-hole flag the producer stamps for a `@stub(T)` /
// `@stub(T, fallback)` body. Nothing else is consulted: the hole verdict was
// the compiler's, the projection only reports it. needle is unused — holes
// takes no argument.
warden_holes_predicate :: proc(decl: Decl_Record, needle: string) -> bool {
	_ = needle
	return decl.stub
}

// warden_debt_predicate is `funpack warden debt` (§29 §4): a declaration is
// debt when its contract `todo` field is true OR its gtags carry the
// registered `debt` tag. The two halves have distinct provenance: the gtag
// half is LIVE (authored @gtag(debt) declarations project today), while the
// todo half is faithfully empty on every current tree — Decl_Record.todo is
// mandatory-present constant-false because the parser does not yet admit
// @todo (index_decl.odin stamps it false on every record). The projection
// reads the contract field AS DEFINED, so when a future parser milestone
// derives todo from source this predicate is already correct with no edit —
// no parser work is smuggled in here. The gtag scan is a linear pass over one
// record's authored-order slice, not a map lookup, so output determinism
// holds (§29 §1). needle is unused — debt takes no argument.
warden_debt_predicate :: proc(decl: Decl_Record, needle: string) -> bool {
	_ = needle
	return decl.todo || slice.contains(decl.gtags, WARDEN_DEBT_GTAG)
}
