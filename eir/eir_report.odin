package eir

import "core:fmt"
import "core:slice"

class_dedup_value :: proc(c: Clone_Class) -> int {
	return c.node_count * (len(c.instances) - 1)
}

class_mass :: proc(c: Clone_Class) -> int {
	return c.node_count * len(c.instances)
}

rank_clone_classes :: proc(classes: []Clone_Class, allocator := context.allocator) -> []Clone_Class {
	ranked := make([]Clone_Class, len(classes), allocator)
	copy(ranked, classes)
	slice.sort_by(ranked, ranked_class_less)
	return ranked
}

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
