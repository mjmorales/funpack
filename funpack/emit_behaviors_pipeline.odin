// The run-schedule serializers of the artifact emitter: [behaviors] (§10),
// [pipeline_flattened] / [signal_routing] (§11, §12), and [setup] (§13). These
// sections project the flattened pipeline and the Startup spawn batch — the
// derived run schedule — so they share the flattened-pipeline inputs and sit
// apart from the static type schema.
package funpack

import "core:strings"

// ───────────────────────────────────────────────────────────────────────────
// [behaviors] — transitions keyed to their pipeline stage
// (docs/artifact-format.md §10)
// ───────────────────────────────────────────────────────────────────────────

// emit_behaviors writes one record per behavior in source-declaration order,
// each carrying its stage slot, the conferred contract, its `@gtag` set, the
// reserved `step` signature (params/emit), and the step body. The stage a
// behavior occupies is read from the flattened pipeline (the step whose behavior
// is this one); the contract is the §06 §6 slot contract that stage confers.
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
		// A §05 §2 holed step carries its hole as the body's single `stub`
		// subtree (schema v7), so a pipelined hole's fallback approximation is
		// live in the runtime, not a silent no-op.
		emit_executable_body(b, decl.step.holed, decl.step.has_fallback, decl.step.fallback, decl.step.body)
	}
}

// behavior_stage returns the pipeline stage a behavior occupies — the stage
// name of the flattened step whose behavior is this one (docs/artifact-format.md
// §10: the slot confers the contract). A behavior referenced in [behaviors] is
// always scheduled, so the lookup always finds a step.
behavior_stage :: proc(flat: Flattened_Pipeline, name: string) -> string {
	for step in flat.order {
		if step.behavior == name {
			return step.stage
		}
	}
	return ""
}

// contract_name maps a pipeline slot to its §06 §6 contract token
// (docs/artifact-format.md §10): Update/Render/Startup/Ui/Audio. The slot is the
// engine-closed contract a stage confers, so the token is the slot's name.
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

// behavior_emits returns the behavior step's return-side emissions
// (docs/artifact-format.md §10): its return is its writes (§06 §3). Each pong
// behavior writes exactly one value — its blackboard, a signal list, or a
// command list — so the emit set is the single rendered return type.
behavior_emits :: proc(decl: Behavior_Node) -> []string {
	emits := make([]string, 1, context.temp_allocator)
	emits[0] = type_ref_string(decl.step.return_type)
	return emits
}

// ───────────────────────────────────────────────────────────────────────────
// [pipeline_flattened] / [signal_routing] — the derived schedule
// (docs/artifact-format.md §11, §12)
// ───────────────────────────────────────────────────────────────────────────

// emit_pipeline_flattened writes the one total order (docs/artifact-format.md
// §11): one `step` line per flattened ordinal, in order, each naming its stage
// and behavior. The order is stage_flatten's depth-first flattening — the order
// the runtime folds — so the ordinals are contiguous and gap-free.
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

// emit_signal_routing writes the producer(s) → consumer(s) map
// (docs/artifact-format.md §12): one `route` record per signal that is emitted
// or consumed anywhere, in signal-declaration order, each followed by its
// producer and consumer endpoints keyed by flattened ordinal. The routes come
// straight from stage_flatten, already in declaration order.
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

// emit_endpoint writes one routing endpoint line (docs/artifact-format.md §12):
// `producer`/`consumer ORDINAL behavior:NAME` — the flattened-order ordinal and
// the behavior at that step, so closure is a forward-flow check over ordinals.
emit_endpoint :: proc(b: ^strings.Builder, role: string, endpoint: Signal_Endpoint) {
	strings.write_string(b, role)
	strings.write_byte(b, ' ')
	strings.write_int(b, endpoint.ordinal)
	emit_line(b, " behavior:", endpoint.behavior)
}

// ───────────────────────────────────────────────────────────────────────────
// [setup] — the Startup [Spawn] program (docs/artifact-format.md §13)
// ───────────────────────────────────────────────────────────────────────────

// emit_setup writes the Startup spawn batch (docs/artifact-format.md §13): one
// `spawn THING field_count` per spawn in the setup() body's source list order,
// each followed by one `set FIELD =ENCODED` per field of the spawned thing's
// blackboard. The batch is EVALUATED at compile time through the full evaluator
// (setup_values.odin resolve_setup_values, the same evaluate.odin surface
// `funpack test` runs), so an idiomatic multi-statement constructor (`new_run`'s
// `let` bindings over generate_floor's whole builtin/operator/match call tree)
// bakes its real spawn; a fold that only inlines single-`return` helpers cannot,
// and would bake an empty [setup] — a black screen. A top-level Vec2 keeps its
// §13 spread; every other field encodes through the recursive §6 token form
// (encode_setup_value_field). The runtime then spawns the initial population
// without interpreting an initializer.
//
// A setup() that EXISTS but does not evaluate to a closed [Spawn] batch returns
// Setup_Eval_Failed — the build GATE refuses loudly rather than emitting a
// silently-empty [setup] (the black-screen failure mode). A module with no
// setup() yields the empty `[setup 0]` batch, the legal no-startup game.
//
// A LEVEL-BACKED setup() — a lone call to a baked level's `<level>_spawns`
// extern (dungeon/warren, schema v15) — folds the threaded bake's spawn list
// instead (emit_level_setup.odin): the extern has no body to evaluate, but the
// batch it stands for is already a pure function of the tree, so the same §13
// no-expressions contract holds.
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

// single_return_list returns the list a body's single `return [list]` statement
// returns. The setup() and (read-side) bindings shapes are a lone `return` of a
// list/builder expression; this reads that list for the [setup] walk.
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

// vec2_component_bits reads a named Fixed component out of a Vec2 record literal
// (docs/artifact-format.md §13: a Vec2 setup value is `vec2 x_bits y_bits`). The
// gate stage proved the setup record well-typed, so the named component is a
// Fixed literal.
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
