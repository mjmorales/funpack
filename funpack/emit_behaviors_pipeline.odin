package funpack

import "core:strings"

emit_behaviors :: proc(b: ^strings.Builder, ast: Ast, flat: Flattened_Pipeline) {
	emit_header(b, "behaviors", len(ast.behaviors))
	for decl in ast.behaviors {
		stage := behavior_stage(flat, decl.name)
		contract := contract_name(slot_of_stage(stage))
		emits := behavior_emits(decl)
		strings.write_string(b, "behavior ")
		strings.write_string(b, decl.name)
		strings.write_string(b, " on:")
		strings.write_string(b, decl.target)
		strings.write_string(b, " stage:")
		strings.write_string(b, stage)
		strings.write_string(b, " contract:")
		strings.write_string(b, contract)
		strings.write_byte(b, ' ')
		strings.write_int(b, len(decl.gtags))
		strings.write_byte(b, ' ')
		strings.write_int(b, len(decl.step.params))
		strings.write_byte(b, ' ')
		strings.write_int(b, len(emits))
		strings.write_byte(b, ' ')
		strings.write_int(b, executable_body_count(decl.step.holed, decl.step.body))
		emit_line(b, "")
		emit_gtags(b, decl.gtags)
		for param in decl.step.params {
			emit_line(b, "param ", param.name, " ", type_ref_string(param.type))
		}
		for emit in emits {
			emit_line(b, "emit ", emit)
		}
		emit_executable_body(b, decl.step.holed, decl.step.has_fallback, decl.step.fallback, decl.step.body)
	}
}

behavior_stage :: proc(flat: Flattened_Pipeline, name: string) -> string {
	for step in flat.order {
		if step.behavior == name {
			return step.stage
		}
	}
	return ""
}

contract_name :: proc(slot: Pipeline_Slot) -> string {
	switch slot {
	case .Update:
		return "Update"
	case .Render:
		return "Render"
	case .Startup:
		return "Startup"
	case .Ui:
		return "Ui"
	case .Audio:
		return "Audio"
	}
	return "Update"
}

behavior_emits :: proc(decl: Behavior_Node) -> []string {
	emits := make([]string, 1, context.temp_allocator)
	emits[0] = type_ref_string(decl.step.return_type)
	return emits
}

emit_pipeline_flattened :: proc(b: ^strings.Builder, flat: Flattened_Pipeline) {
	emit_header(b, "pipeline_flattened", len(flat.order))
	for step in flat.order {
		strings.write_string(b, "step ")
		strings.write_int(b, step.ordinal)
		strings.write_string(b, " stage:")
		strings.write_string(b, step.stage)
		emit_line(b, " behavior:", step.behavior)
	}
}

emit_signal_routing :: proc(b: ^strings.Builder, flat: Flattened_Pipeline) {
	emit_header(b, "signal_routing", len(flat.routes))
	for route in flat.routes {
		strings.write_string(b, "route ")
		strings.write_string(b, route.signal)
		strings.write_byte(b, ' ')
		strings.write_int(b, len(route.producers))
		strings.write_byte(b, ' ')
		strings.write_int(b, len(route.consumers))
		emit_line(b, "")
		for producer in route.producers {
			emit_endpoint(b, "producer", producer)
		}
		for consumer in route.consumers {
			emit_endpoint(b, "consumer", consumer)
		}
	}
}

emit_endpoint :: proc(b: ^strings.Builder, role: string, endpoint: Signal_Endpoint) {
	strings.write_string(b, role)
	strings.write_byte(b, ' ')
	strings.write_int(b, endpoint.ordinal)
	emit_line(b, " behavior:", endpoint.behavior)
}

emit_setup :: proc(b: ^strings.Builder, ctx: Eval_Ctx, batches: []Level_Spawn_Batch, imported_things: []Thing_Node) -> Emit_Error {
	if batch, found := level_setup_batch(ctx.ast, batches); found {
		emit_level_setup(b, batch, ctx.ast.things, imported_things)
		return .None
	}
	spawns, _, ok := resolve_setup_values(ctx)
	if !ok {
		return .Setup_Eval_Failed
	}
	emit_header(b, "setup", len(spawns))
	for spawn in spawns {
		strings.write_string(b, "spawn ")
		strings.write_string(b, spawn.type_name)
		strings.write_byte(b, ' ')
		strings.write_int(b, len(spawn.record.fields))
		emit_line(b, "")
		for field in spawn.record.fields {
			encoded, enc_ok := encode_setup_value_field(field.value)
			if !enc_ok {
				return .Setup_Eval_Failed
			}
			emit_line(b, "set ", field.name, " =", encoded)
		}
	}
	return .None
}

single_return_list :: proc(body: []Statement) -> (list: ^List_Expr, ok: bool) {
	if len(body) != 1 {
		return nil, false
	}
	ret, is_return := body[0].(Return_Node)
	if !is_return {
		return nil, false
	}
	list, ok = ret.value.(^List_Expr)
	return
}

vec2_component_bits :: proc(record: ^Record_Expr, name: string) -> Fixed {
	for field in record.fields {
		if field.name == name {
			if lit, ok := field.value.(^Fixed_Lit_Expr); ok {
				return lit.bits
			}
		}
	}
	return Fixed(0)
}
