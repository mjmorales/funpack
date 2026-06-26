// The dup RATCHET: a committed baseline of the current clone debt and a gate that
// fails only when debt rises ABOVE it. This turns `eir dup` from a pure report into a
// monotone-tightening CI gate without red-lighting the existing debt on introduction —
// the baseline records the clones present when it is snapshotted, the gate permits
// anything at or below them, and a deliberate re-snapshot (--update-baseline) is the only
// way the ceiling moves, so the committed baseline diff is the audit trail of every debt
// change.
//
// The ratchet number is total_dedup_value — the sum over every clone class of
// node_count * (instances - 1), the nodes a full dedup would remove. It is the gate's
// decision key because it is LINE-NUMBER INDEPENDENT (a class's leverage is its shape
// and site count, never its span) and collision-proof (a 64-bit fnv64a digest collision
// between two distinct-canon classes cannot perturb a SUM over all classes). So a
// refactor that shifts code without adding duplication leaves the total untouched, and
// only genuinely new or grown duplication pushes it up and trips the gate.
//
// The per-class set is recorded too (content-addressed by the class's fnv64a digest, the
// same id the --json report exposes) so a failure can NAME which class is new or grew,
// not just report that the total moved. The set is diagnostic; the total is the verdict.
package eir

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

// DUP_BASELINE_SCHEMA_VERSION leads the baseline JSON so a consumer reads the shape
// version before the body — the same self-describing lead the dup report uses.
DUP_BASELINE_SCHEMA_VERSION :: 1

// Dup_Baseline is the whole committed baseline as one marshal-able struct: field order
// is the emitted key order and every field is a scalar or an index-ordered slice (no
// map), so json.marshal over the same debt is byte-identical run to run. min_nodes,
// fold_literals, and excludes pin the SCAN that produced it — a gate run under different
// options sees a different class set, so the gate refuses to compare across a mismatch
// rather than report a phantom regression. total_dedup_value is the ratchet ceiling;
// classes is the content-addressed debt set, sorted for byte-stability.
Dup_Baseline :: struct {
	schema_version:    int,
	min_nodes:         int,
	fold_literals:     bool,
	excludes:          []string,
	total_dedup_value: int,
	classes:           []Baseline_Class,
}

// Baseline_Class is one clone class as recorded debt: id is the class's fnv64a digest as
// a zero-padded 16-hex string (the content address — the same id the --json report
// exposes, stable across line drift), and kind/node_count/instances/dedup_value mirror
// the class so a gate failure can describe it without re-deriving anything.
Baseline_Class :: struct {
	id:          string,
	kind:        string,
	node_count:  int,
	instances:   int,
	dedup_value: int,
}

// Gate_Verdict is the comparison outcome: regressed is the verdict (current debt exceeds
// the baseline ceiling), the two totals frame it, and new_classes/grown_classes pinpoint
// what moved — content-ids absent from the baseline, and content-ids present in both
// whose instance count rose. The diagnostic lists may be empty on a fnv64a-collision edge
// even when regressed is true; the totals are always authoritative.
Gate_Verdict :: struct {
	regressed:      bool,
	baseline_total: int,
	current_total:  int,
	new_classes:    []Baseline_Class,
	grown_classes:  []Baseline_Class,
}

// build_baseline projects the engine's clone classes onto the recorded debt set: each
// class becomes a Baseline_Class keyed by its fnv64a digest, the total is summed over
// every class (collision-proof — a sum needs no unique ids), and the set is sorted into
// a deterministic order so the serialized file is byte-stable. opts and excludes are
// stamped in so a later gate run can prove it scanned the same way.
build_baseline :: proc(
	classes: []Clone_Class,
	opts: Dup_Options,
	excludes: []string,
	allocator := context.allocator,
) -> Dup_Baseline {
	recorded := make([]Baseline_Class, len(classes), allocator)
	total := 0
	for c, i in classes {
		dv := class_dedup_value(c)
		total += dv
		recorded[i] = Baseline_Class {
			id          = fmt.aprintf("%016x", c.hash, allocator = allocator),
			kind        = c.kind,
			node_count  = c.node_count,
			instances   = len(c.instances),
			dedup_value = dv,
		}
	}
	slice.sort_by(recorded, baseline_class_less)

	ex := make([]string, len(excludes), allocator)
	copy(ex, excludes)
	slice.sort(ex)

	return Dup_Baseline {
		schema_version    = DUP_BASELINE_SCHEMA_VERSION,
		min_nodes         = opts.min_nodes,
		fold_literals     = opts.fold_literals,
		excludes          = ex,
		total_dedup_value = total,
		classes           = recorded,
	}
}

// baseline_class_less is the total order on recorded classes: by content id, then by the
// class's own fields. A fnv64a collision can seat two distinct classes at one id, so the
// id alone is not a total order — the kind/node_count/instances tie-break keeps the
// serialized set deterministic even then.
@(private = "file")
baseline_class_less :: proc(a, b: Baseline_Class) -> bool {
	if a.id != b.id {
		return a.id < b.id
	}
	if a.kind != b.kind {
		return a.kind < b.kind
	}
	if a.node_count != b.node_count {
		return a.node_count < b.node_count
	}
	return a.instances < b.instances
}

// render_baseline_json marshals the baseline to a byte-stable JSON object: the ordered
// struct (no map anywhere) plus the pre-sorted class set means a double render over the
// same debt is byte-identical, so the committed file changes ONLY when the debt does. A
// trailing newline is added — a committed file ends in one. Allocated in `allocator`.
render_baseline_json :: proc(baseline: Dup_Baseline, allocator := context.allocator) -> string {
	bytes, _ := json.marshal(baseline, {pretty = true}, context.temp_allocator)
	return strings.concatenate({string(bytes), "\n"}, allocator)
}

// parse_baseline unmarshals a committed baseline file. ok is false on malformed JSON or a
// schema version the gate does not understand — the caller surfaces that as a usage error
// (a stale baseline is operator-fixable, never a silent pass).
parse_baseline :: proc(
	data: string,
	allocator := context.allocator,
) -> (
	baseline: Dup_Baseline,
	ok: bool,
) {
	if json.unmarshal_string(data, &baseline, allocator = allocator) != nil {
		return {}, false
	}
	if baseline.schema_version != DUP_BASELINE_SCHEMA_VERSION {
		return {}, false
	}
	return baseline, true
}

// baseline_scan_matches reports whether a gate run's scan options match the baseline's
// recorded ones. A mismatch means the two class sets are not comparable (a different
// min_nodes floor or fold-literals mode or exclude set yields a different debt), so the
// gate refuses the comparison instead of reporting a phantom regression. excludes are
// compared as sorted sets — build_baseline sorts what it stores, so the gate sorts its
// own list to match.
baseline_scan_matches :: proc(
	baseline: Dup_Baseline,
	opts: Dup_Options,
	excludes: []string,
) -> bool {
	if baseline.min_nodes != opts.min_nodes || baseline.fold_literals != opts.fold_literals {
		return false
	}
	if len(baseline.excludes) != len(excludes) {
		return false
	}
	sorted := make([]string, len(excludes), context.temp_allocator)
	copy(sorted, excludes)
	slice.sort(sorted)
	for ex, i in sorted {
		if baseline.excludes[i] != ex {
			return false
		}
	}
	return true
}

// compare_baseline runs the ratchet: project the current classes, sum the current total,
// and decide regressed = current_total > baseline_total. The diagnostics walk the current
// set against the baseline's id→instances map — an id absent from the baseline is a new
// class, an id present whose instance count rose is a grown one. The verdict turns on the
// totals alone (collision-proof); the diagnostic lists are best-effort labels for the
// failure message.
compare_baseline :: proc(
	baseline: Dup_Baseline,
	current: []Clone_Class,
	opts: Dup_Options,
	excludes: []string,
	allocator := context.allocator,
) -> Gate_Verdict {
	current_baseline := build_baseline(current, opts, excludes, context.temp_allocator)

	prior := make(map[string]int, len(baseline.classes), context.temp_allocator)
	for bc in baseline.classes {
		prior[bc.id] = bc.instances
	}

	new_classes := make([dynamic]Baseline_Class, 0, 8, allocator)
	grown_classes := make([dynamic]Baseline_Class, 0, 8, allocator)
	for cc in current_baseline.classes {
		prior_instances, seen := prior[cc.id]
		if !seen {
			append(&new_classes, cc)
		} else if cc.instances > prior_instances {
			append(&grown_classes, cc)
		}
	}

	return Gate_Verdict {
		regressed      = current_baseline.total_dedup_value > baseline.total_dedup_value,
		baseline_total = baseline.total_dedup_value,
		current_total  = current_baseline.total_dedup_value,
		new_classes    = new_classes[:],
		grown_classes  = grown_classes[:],
	}
}

// render_gate_failure renders the human explanation of a regressed verdict: the two
// totals, then the new and grown classes that account for the rise. It is only called on
// a regression — a pass prints its own one-line note — so it always has a delta to show.
// Allocated in `allocator`.
render_gate_failure :: proc(verdict: Gate_Verdict, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintfln(
		&b,
		"eir dup: clone debt rose above baseline (total dedup_value %d -> %d)",
		verdict.baseline_total,
		verdict.current_total,
	)
	for nc in verdict.new_classes {
		fmt.sbprintfln(
			&b,
			"  new clone class %s (%s, %d nodes x %d sites, dedup_value %d)",
			nc.id,
			nc.kind,
			nc.node_count,
			nc.instances,
			nc.dedup_value,
		)
	}
	for gc in verdict.grown_classes {
		fmt.sbprintfln(
			&b,
			"  grown clone class %s (%s, now %d sites, dedup_value %d)",
			gc.id,
			gc.kind,
			gc.instances,
			gc.dedup_value,
		)
	}
	strings.write_string(
		&b,
		"run `eir dup` to see the clones, dedup them, then `eir dup --baseline <file> --update-baseline` to tighten\n",
	)
	return strings.to_string(b)
}
