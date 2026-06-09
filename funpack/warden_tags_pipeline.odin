// The two project-record-side warden projections (§29 §1/§4): `funpack warden
// tags` and `funpack warden pipeline`. Both are pure functions of the decoded
// Warden_Index — bytes out, no clock, no AST, no recompute — answering over
// the contract exactly as the index recorded it.
//
// `tags` is the registry ⋈ gtags JOIN: one NDJSON line per REGISTERED tag in
// Project_Record.tag_registry's AUTHORED order (the tags.fcfg order the
// producer emitted — never re-sorted, no map iteration), each carrying the
// qualified_names of the decls that attach it in decl-stream order. The join
// is total by construction — an unregistered @gtag is already a P7 compile
// error upstream, so every attached tag is in the registry — and a registered
// tag with zero uses emits an EMPTY decls list, never an omitted key (dead-tag
// visibility, mirroring the contract's absence-is-an-empty-list rule).
//
// `pipeline` re-projects the recorded §07 §3 depth-first total order: one
// NDJSON line per Flat_Step_Record (ordinal/stage/behavior) positionally as
// Project_Record.pipeline_flattened pinned it — the flatten is never re-run,
// the contract IS the order. A package with no pipeline projects zero lines,
// which is still success (the warden's exit tiers stay {0, 2}; emptiness is
// not a failure).
package funpack

import "core:encoding/json"
import "core:strings"

// Warden_Tag_Record is one `funpack warden tags` output line: the registered
// tag and the qualified_names of the decls carrying it. Field declaration
// order is the emitted JSON key order (the Decl_Record marshal convention),
// so `tag` leads. decls is [] for a registered-but-unused tag — present,
// never omitted.
Warden_Tag_Record :: struct {
	tag:   string,
	decls: []string,
}

// warden_tags_ndjson projects the decoded index onto the `tags` NDJSON
// output: one Warden_Tag_Record line per tag_registry entry, in the
// registry's authored order. Each tag's decls list collects qualified_names
// by a forward walk over index.decls (decl-stream order — the emission order
// the decode preserved), so neither axis of the join is ever re-sorted and
// the bytes are deterministic (§29 §1). An empty registry projects the empty
// string — zero lines, success.
warden_tags_ndjson :: proc(index: Warden_Index, allocator := context.allocator) -> string {
	lines := make([dynamic]string, 0, len(index.project.tag_registry), context.temp_allocator)
	for tag in index.project.tag_registry {
		carriers := make([dynamic]string, context.temp_allocator)
		for decl in index.decls {
			for gtag in decl.gtags {
				if gtag == tag {
					append(&carriers, decl.qualified_name)
					break
				}
			}
		}
		record := Warden_Tag_Record {
			tag   = tag,
			decls = carriers[:],
		}
		append(&lines, warden_record_line(record, context.temp_allocator))
	}
	return strings.concatenate(lines[:], allocator)
}

// warden_pipeline_ndjson projects the decoded index onto the `pipeline`
// NDJSON output: one line per Flat_Step_Record in
// Project_Record.pipeline_flattened, positionally — the recorded depth-first
// ordinal order is the output order, no recomputation and no flatten re-run
// (the query answers over the contract, never the AST). An empty
// pipeline_flattened projects the empty string — zero lines, success.
warden_pipeline_ndjson :: proc(index: Warden_Index, allocator := context.allocator) -> string {
	lines := make([dynamic]string, 0, len(index.project.pipeline_flattened), context.temp_allocator)
	for step in index.project.pipeline_flattened {
		append(&lines, warden_record_line(step, context.temp_allocator))
	}
	return strings.concatenate(lines[:], allocator)
}

// warden_record_line encodes one projection record as one NDJSON line — the
// compact struct marshal plus a single LF, the emit_decl_record transport
// shape on the consumer side. The struct marshals in field-declaration order
// with no map, so a double encoding of the same record is byte-identical. An
// empty slice field marshals as [] — present, never omitted.
warden_record_line :: proc(record: $T, allocator := context.allocator) -> string {
	bytes, _ := json.marshal(record, {use_enum_names = true}, context.temp_allocator)
	return strings.concatenate({string(bytes), "\n"}, allocator)
}
