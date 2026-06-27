package eir

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

DUP_BASELINE_SCHEMA_VERSION :: 1

Dup_Baseline :: struct {
	schema_version:    int,
	min_nodes:         int,
	fold_literals:     bool,
	excludes:          []string,
	total_dedup_value: int,
	classes:           []Baseline_Class,
}

Baseline_Class :: struct {
	id:          string,
	kind:        string,
	node_count:  int,
	instances:   int,
	dedup_value: int,
}

Gate_Verdict :: struct {
	regressed:      bool,
	baseline_total: int,
	current_total:  int,
	new_classes:    []Clone_Class,
	grown_classes:  []Clone_Class,
}

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

render_baseline_json :: proc(baseline: Dup_Baseline, allocator := context.allocator) -> string {
	bytes, _ := json.marshal(baseline, {pretty = true}, context.temp_allocator)
	return strings.concatenate({string(bytes), "\n"}, allocator)
}

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

compare_baseline :: proc(
	baseline: Dup_Baseline,
	current: []Clone_Class,
	opts: Dup_Options,
	excludes: []string,
	allocator := context.allocator,
) -> Gate_Verdict {
	prior := make(map[string]int, len(baseline.classes), context.temp_allocator)
	for bc in baseline.classes {
		prior[bc.id] = bc.instances
	}

	current_total := 0
	new_classes := make([dynamic]Clone_Class, 0, 8, allocator)
	grown_classes := make([dynamic]Clone_Class, 0, 8, allocator)
	for cc in current {
		current_total += class_dedup_value(cc)
		id := fmt.aprintf("%016x", cc.hash, allocator = context.temp_allocator)
		prior_instances, seen := prior[id]
		if !seen {
			append(&new_classes, cc)
		} else if len(cc.instances) > prior_instances {
			append(&grown_classes, cc)
		}
	}

	return Gate_Verdict {
		regressed      = current_total > baseline.total_dedup_value,
		baseline_total = baseline.total_dedup_value,
		current_total  = current_total,
		new_classes    = new_classes[:],
		grown_classes  = grown_classes[:],
	}
}

render_gate_failure :: proc(verdict: Gate_Verdict, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintfln(
		&b,
		"eir dup: clone debt rose above baseline (total dedup_value %d -> %d)",
		verdict.baseline_total,
		verdict.current_total,
	)

	offending := make([dynamic]Clone_Class, 0, len(verdict.new_classes) + len(verdict.grown_classes), context.temp_allocator)
	append(&offending, ..verdict.new_classes)
	append(&offending, ..verdict.grown_classes)
	diags := dup_diagnostics(offending[:], .Error, context.temp_allocator)
	strings.write_string(&b, render_diagnostics_human(diags, context.temp_allocator))

	strings.write_string(
		&b,
		"dedup the clones above, then `eir dup --baseline <file> --update-baseline` to tighten\n",
	)
	return strings.to_string(b)
}
