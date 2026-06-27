package funpack

import "core:encoding/json"
import "core:strings"

Warden_Tag_Record :: struct {
	tag:   string,
	decls: []string,
}

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

warden_pipeline_ndjson :: proc(index: Warden_Index, allocator := context.allocator) -> string {
	lines := make([dynamic]string, 0, len(index.project.pipeline_flattened), context.temp_allocator)
	for step in index.project.pipeline_flattened {
		append(&lines, warden_record_line(step, context.temp_allocator))
	}
	return strings.concatenate(lines[:], allocator)
}

warden_record_line :: proc(record: $T, allocator := context.allocator) -> string {
	bytes, _ := json.marshal(record, {use_enum_names = true}, context.temp_allocator)
	return strings.concatenate({string(bytes), "\n"}, allocator)
}
