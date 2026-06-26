// The dup REPORT surface: it turns the clone engine's []Clone_Class into ranked
// []Diagnostic for the shared diagnostic renderers, and owns nothing the engine owns. It
// re-ranks the classes by leverage (it does NOT re-walk ASTs or re-cluster), so the engine
// stays the algorithm and the report stays presentation — the projection is leverage-first,
// so the highest-value dedup target leads the diagnostic stream.
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
// emitted diagnostic stream byte-stable.
package eir

import "core:fmt"
import "core:slice"

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

// dup_diagnostics projects the clone classes onto the shared diagnostic surface, ranked by
// leverage: one Diagnostic per class at the given severity, ordered dedup_value-descending,
// its primary location the class's first site and the remaining sites attached as `note:`
// related locations. The message carries the leverage metric (kind, site count, dedup value)
// so the highest-value dedup target leads the stream and reads at a glance. The severity is a
// parameter because the bare report emits Warnings while the ratchet gate emits Errors on the
// offending classes — same projection, different level. The diagnostics borrow the loader's
// path strings; keep the loader alive while reading them. Allocated in `allocator`.
dup_diagnostics :: proc(
	classes: []Clone_Class,
	severity: Severity,
	allocator := context.allocator,
) -> []Diagnostic {
	ranked := rank_clone_classes(classes, context.temp_allocator)
	out := make([]Diagnostic, len(ranked), allocator)
	for c, i in ranked {
		n := len(c.instances)
		related := make([]Related_Location, n - 1, allocator)
		for k in 1 ..< n {
			inst := c.instances[k]
			related[k - 1] = Related_Location {
				file = inst.path,
				line = inst.line_start,
				col  = inst.col,
				note = fmt.aprintf("clone site %d of %d", k + 1, n, allocator = allocator),
			}
		}
		first := c.instances[0]
		out[i] = Diagnostic {
			file     = first.path,
			line     = first.line_start,
			col      = first.col,
			severity = severity,
			rule     = "dup",
			message  = fmt.aprintf(
				"duplicated %s, %d sites, dedup %d",
				c.kind,
				n,
				class_dedup_value(c),
				allocator = allocator,
			),
			related  = related,
		}
	}
	return out
}
