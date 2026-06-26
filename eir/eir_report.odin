// The dup REPORT surface: it turns the clone engine's []Clone_Class into the two
// operator-facing renderings — a ranked human table and a byte-stable JSON array —
// and owns nothing the engine owns. It re-ranks the classes by leverage (it does NOT
// re-walk ASTs or re-cluster), so the engine stays the algorithm and the report stays
// presentation. Both renderings rank identically, so the JSON's order matches the
// table's row order.
//
// Leverage is two metrics over a class of `node_count`-sized subtrees repeated across
// `instances` sites:
//
//   - dedup_value = node_count * (instances - 1) — the nodes SAVED by collapsing the
//     class to one definition (every repeat past the first is removable). This is the
//     ranking key: the highest-dedup_value class is the highest-leverage refactor.
//   - mass = node_count * instances — the GROSS duplicated size (every site counted).
//     Reported for sizing, not ranking; a two-instance giant and a many-instance small
//     class can share a mass while differing sharply in dedup_value.
//
// The rank order is (dedup_value desc, hash asc, first-span asc): leverage first, then
// the engine's own deterministic tie-breaks. The hash is a bucket index, not a unique
// class id (a 64-bit fnv64a collision can seat two distinct-canon classes at one
// hash), so the first-span tie-break is load-bearing: (dedup_value, hash, first-span)
// is a total order — ranking is a pure function of the class set, independent of the
// input slice's order and of any map iteration. That determinism is what makes the
// JSON byte-stable.
package eir

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

// DUP_REPORT_SCHEMA_VERSION leads the JSON object so a consumer reads the shape
// version before the classes — the same self-describing convention surface_dump uses.
DUP_REPORT_SCHEMA_VERSION :: 1

// Dup_Report is the whole --json payload as one marshal-able struct: field-declaration
// order is the emitted key order and every field is a scalar or an index-ordered slice
// — no map is marshaled — so json.marshal over the same class set is byte-identical
// run to run. It is the report's public schema (a consumer unmarshals into it).
Dup_Report :: struct {
	schema_version: int,
	clone_classes:  []Dup_Class_Record,
}

// Dup_Class_Record is one ranked clone class in the JSON: rank (1-based, by leverage),
// the two leverage metrics, the subtree size and site count, the clone-root kind, the
// fnv64a bucket digest as a zero-padded 16-hex-digit string (a string, not a JSON
// number, so a full u64 survives without the number-precision loss a consumer's
// parser might apply),
// and the per-site locations. The leading rank/dedup_value/mass let an agent pick the
// highest-leverage dedup target from the head of the array without re-deriving it.
Dup_Class_Record :: struct {
	rank:        int,
	dedup_value: int,
	mass:        int,
	node_count:  int,
	instances:   int,
	kind:        string,
	hash:        string,
	sites:       []Dup_Site_Record,
}

// Dup_Site_Record is one occurrence in the JSON: where the duplicated subtree sits and
// whether it is test code (so a consumer can scope production vs test duplication).
Dup_Site_Record :: struct {
	path:       string,
	is_test:    bool,
	line_start: int,
	line_end:   int,
}

// class_dedup_value returns the nodes saved by deduping a class to one definition:
// node_count * (instances - 1). A two-instance class saves one copy's worth; an
// N-instance class saves N-1. This is the report's ranking key.
class_dedup_value :: proc(c: Clone_Class) -> int {
	return c.node_count * (len(c.instances) - 1)
}

// class_mass returns the gross duplicated size: node_count * instances, every site
// counted. Reported alongside dedup_value for sizing; never the ranking key.
class_mass :: proc(c: Clone_Class) -> int {
	return c.node_count * len(c.instances)
}

// rank_clone_classes returns a COPY of the classes sorted by leverage — dedup_value
// desc, then hash asc, then first-span asc. It copies first so the caller's slice
// order is untouched, and the comparator is a total order (the first-span tie-break
// covers a shared-hash collision), so the result is a deterministic function of the
// class SET alone (shuffling the input yields the same ranked output).
rank_clone_classes :: proc(classes: []Clone_Class, allocator := context.allocator) -> []Clone_Class {
	ranked := make([]Clone_Class, len(classes), allocator)
	copy(ranked, classes)
	slice.sort_by(ranked, ranked_class_less)
	return ranked
}

// ranked_class_less is the leverage order: higher dedup_value first, then the engine's
// own deterministic tie-breaks (hash asc, then first-instance span asc). The span
// tie-break is load-bearing: a 64-bit hash collision can seat two distinct classes at
// one hash, and the first-instance span breaks that tie deterministically.
@(private = "file")
ranked_class_less :: proc(a, b: Clone_Class) -> bool {
	da := class_dedup_value(a)
	db := class_dedup_value(b)
	if da != db {
		return da > db
	}
	if a.hash != b.hash {
		return a.hash < b.hash
	}
	ai := a.instances[0]
	bi := b.instances[0]
	if ai.path != bi.path {
		return ai.path < bi.path
	}
	if ai.line_start != bi.line_start {
		return ai.line_start < bi.line_start
	}
	return ai.line_end < bi.line_end
}

// render_dup_json renders the ranked classes as one byte-stable JSON object: a compact
// marshal of the ordered Dup_Report struct (no map anywhere), so a double render over
// the same class set is byte-identical. An empty class set renders an empty
// clone_classes array (a JSON slice marshals as `[]`, never `null`), never a special
// case. No trailing newline — the caller adds one — matching the version --json
// convention. Allocated in `allocator`.
render_dup_json :: proc(classes: []Clone_Class, allocator := context.allocator) -> string {
	report := build_dup_report(classes, context.temp_allocator)
	bytes, _ := json.marshal(report, {}, context.temp_allocator)
	return strings.clone(string(bytes), allocator)
}

// build_dup_report ranks the classes and projects them onto the JSON record structs,
// stamping each with its 1-based rank and computed leverage metrics. The hash renders
// as a zero-padded 16-hex-digit string so a full u64 round-trips losslessly.
@(private = "file")
build_dup_report :: proc(classes: []Clone_Class, allocator := context.allocator) -> Dup_Report {
	ranked := rank_clone_classes(classes, allocator)
	records := make([]Dup_Class_Record, len(ranked), allocator)
	for c, i in ranked {
		sites := make([]Dup_Site_Record, len(c.instances), allocator)
		for inst, k in c.instances {
			sites[k] = Dup_Site_Record {
				path       = inst.path,
				is_test    = inst.is_test,
				line_start = inst.line_start,
				line_end   = inst.line_end,
			}
		}
		records[i] = Dup_Class_Record {
			rank        = i + 1,
			dedup_value = class_dedup_value(c),
			mass        = class_mass(c),
			node_count  = c.node_count,
			instances   = len(c.instances),
			kind        = c.kind,
			hash        = fmt.aprintf("%016x", c.hash, allocator = allocator),
			sites       = sites,
		}
	}
	return Dup_Report{schema_version = DUP_REPORT_SCHEMA_VERSION, clone_classes = records}
}

// REPORT_INDENT and REPORT_GAP are the table's fixed two-space lead-in and inter-column
// separators; the per-column widths below are computed from the data so the columns
// align to the widest cell.
@(private = "file")
REPORT_INDENT :: "  "
@(private = "file")
REPORT_GAP :: "  "

// render_dup_human renders the ranked classes as an aligned text table — columns rank,
// dedup, instance count, clone kind, and the file:line-line span of every site (the
// first site on the class's row, the rest on continuation lines aligned under it). An
// empty class set renders the single "no clones found" line. Allocated in `allocator`.
render_dup_human :: proc(classes: []Clone_Class, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	if len(classes) == 0 {
		strings.write_string(&b, "no clones found\n")
		return strings.to_string(b)
	}
	ranked := rank_clone_classes(classes, context.temp_allocator)

	rank_w := len("rank")
	dedup_w := len("dedup")
	inst_w := len("inst")
	kind_w := len("kind")
	for c, i in ranked {
		rank_w = max(rank_w, len(fmt.tprintf("%d", i + 1)))
		dedup_w = max(dedup_w, len(fmt.tprintf("%d", class_dedup_value(c))))
		inst_w = max(inst_w, len(fmt.tprintf("%d", len(c.instances))))
		kind_w = max(kind_w, len(c.kind))
	}

	write_row_prefix(&b, "rank", "dedup", "inst", "kind", rank_w, dedup_w, inst_w, kind_w)
	strings.write_string(&b, "sites")
	strings.write_byte(&b, '\n')

	cont_prefix :=
		len(REPORT_INDENT) +
		rank_w +
		len(REPORT_GAP) +
		dedup_w +
		len(REPORT_GAP) +
		inst_w +
		len(REPORT_GAP) +
		kind_w +
		len(REPORT_GAP)

	for c, i in ranked {
		write_row_prefix(
			&b,
			fmt.tprintf("%d", i + 1),
			fmt.tprintf("%d", class_dedup_value(c)),
			fmt.tprintf("%d", len(c.instances)),
			c.kind,
			rank_w,
			dedup_w,
			inst_w,
			kind_w,
		)
		for inst, k in c.instances {
			if k > 0 {
				strings.write_byte(&b, '\n')
				write_spaces(&b, cont_prefix)
			}
			fmt.sbprintf(&b, "%s:%d-%d", inst.path, inst.line_start, inst.line_end)
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// write_row_prefix writes the four left-aligned scalar columns (rank, dedup, inst,
// kind) of one table row, each padded to its computed width and followed by the
// inter-column gap, leaving the builder positioned at the sites column. The header row
// and every data row share this layout, so a column header sits exactly over its cells.
@(private = "file")
write_row_prefix :: proc(
	b: ^strings.Builder,
	rank, dedup, inst, kind: string,
	rank_w, dedup_w, inst_w, kind_w: int,
) {
	strings.write_string(b, REPORT_INDENT)
	write_cell(b, rank, rank_w)
	strings.write_string(b, REPORT_GAP)
	write_cell(b, dedup, dedup_w)
	strings.write_string(b, REPORT_GAP)
	write_cell(b, inst, inst_w)
	strings.write_string(b, REPORT_GAP)
	write_cell(b, kind, kind_w)
	strings.write_string(b, REPORT_GAP)
}

// write_cell writes a left-aligned cell: the value, then spaces padding it to width.
// A value already at or over width is written as-is (the width was computed as the max
// over all cells, so over-runs do not occur for the columns this serves).
@(private = "file")
write_cell :: proc(b: ^strings.Builder, value: string, width: int) {
	strings.write_string(b, value)
	write_spaces(b, width - len(value))
}

// write_spaces writes n spaces (a no-op for n <= 0).
@(private = "file")
write_spaces :: proc(b: ^strings.Builder, n: int) {
	for _ in 0 ..< n {
		strings.write_byte(b, ' ')
	}
}
