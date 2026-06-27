package funpack

import "core:strings"

Probe_Record :: struct {
	kind:   string,
	target: string,
	body:   Expr,
}

collect_probe_records :: proc(ast: Ast, allocator := context.allocator) -> []Probe_Record {
	out := make([dynamic]Probe_Record, 0, 4, allocator)
	for ref in ast.decls {
		probes: []Debug_Probe
		name: string
		switch ref.kind {
		case .Let:
			probes = ast.lets[ref.index].probes
			name = ast.lets[ref.index].name
		case .Data:
			probes = ast.datas[ref.index].probes
			name = ast.datas[ref.index].name
		case .Enum:
			probes = ast.enums[ref.index].probes
			name = ast.enums[ref.index].name
		case .Thing:
			probes = ast.things[ref.index].probes
			name = ast.things[ref.index].name
		case .Signal:
			probes = ast.signals[ref.index].probes
			name = ast.signals[ref.index].name
		case .Fn:
			probes = ast.fns[ref.index].probes
			name = ast.fns[ref.index].name
		case .Query:
			probes = ast.queries[ref.index].probes
			name = ast.queries[ref.index].name
		case .Behavior:
			probes = ast.behaviors[ref.index].probes
			name = ast.behaviors[ref.index].name
		case .Pipeline:
			probes = ast.pipelines[ref.index].probes
			name = ast.pipelines[ref.index].name
		case .Extern_Type:
			probes = ast.extern_types[ref.index].probes
			name = ast.extern_types[ref.index].name
		case .Test:
		}
		for probe in probes {
			append(&out, Probe_Record{kind = probe_directive_name(probe.kind), target = name, body = probe.arg})
		}
		#partial switch ref.kind {
		case .Data:
			append_field_probes(&out, name, ast.datas[ref.index].fields)
		case .Thing:
			append_field_probes(&out, name, ast.things[ref.index].fields)
		case .Signal:
			append_field_probes(&out, name, ast.signals[ref.index].fields)
		case .Pipeline:
			append_stage_probes(&out, name, ast.pipelines[ref.index].stages)
		}
	}
	return out[:]
}

append_field_probes :: proc(out: ^[dynamic]Probe_Record, owner: string, fields: []Field_Decl) {
	for field in fields {
		for probe in field.probes {
			append(out, Probe_Record{
				kind   = probe_directive_name(probe.kind),
				target = qualify_probe_site(owner, field.name),
				body   = probe.arg,
			})
		}
	}
}

append_stage_probes :: proc(out: ^[dynamic]Probe_Record, pipeline: string, stages: []Pipeline_Stage) {
	for stage in stages {
		for probe in stage.probes {
			append(out, Probe_Record{
				kind   = probe_directive_name(probe.kind),
				target = qualify_probe_site(pipeline, stage.name),
				body   = probe.arg,
			})
		}
	}
}

qualify_probe_site :: proc(owner: string, member: string) -> string {
	return strings.concatenate({owner, ".", member}, context.temp_allocator)
}

emit_probes :: proc(b: ^strings.Builder, ast: Ast) {
	records := collect_probe_records(ast, context.temp_allocator)
	emit_header(b, "probes", len(records))
	for record in records {
		has_body := record.body != nil
		strings.write_string(b, "probe ")
		strings.write_string(b, record.kind)
		strings.write_byte(b, ' ')
		strings.write_string(b, record.target)
		strings.write_byte(b, ' ')
		strings.write_int(b, 1 if has_body else 0)
		emit_line(b, "")
		if has_body {
			emit_expr(b, record.body)
		}
	}
}
