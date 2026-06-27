package funpack

import "core:strings"

Emit_Input :: struct {
	ast:          Ast,
	typed:        Typed_Ast,
	flat:         Flattened_Pipeline,
	module:       string,
	project:      Project_Identity,
	entrypoint:   Entrypoint_Config,
	imported_fns: []Function_Record,
	imported_decls: Imported_Decls,
	level_spawns: []Level_Spawn_Batch,
	tilemaps:     []Baked_Tile_Layer,
	nav_graphs:   []Baked_Nav_Graph,
	assets:       Baked_Assets,
}

Emit_Error :: enum {
	None,
	Parse_Failed,
	Gate_Failed,
	Typecheck_Failed,
	Contract_Failed,
	Flatten_Failed,
	Entrypoint_Failed,
	Whole_Module_Collision,
	Setup_Eval_Failed,
}

stage_emit :: proc(
	source: string,
	module: string,
	project: Project_Identity,
	entrypoint_fcfg: string,
	allocator := context.allocator,
) -> (artifact: string, err: Emit_Error) {
	return stage_emit_indexed(source, module, project, entrypoint_fcfg, Module_Index{}, nil, nil, nil, nil, Baked_Assets{}, allocator)
}

stage_emit_indexed :: proc(
	source: string,
	module: string,
	project: Project_Identity,
	entrypoint_fcfg: string,
	index: Module_Index,
	module_asts: map[string]Ast,
	tilemaps: []Baked_Tile_Layer = nil,
	nav_graphs: []Baked_Nav_Graph = nil,
	level_spawns: []Level_Spawn_Batch = nil,
	assets: Baked_Assets = {},
	allocator := context.allocator,
) -> (artifact: string, err: Emit_Error) {
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return "", .Parse_Failed
	}
	if stage_gates(ast) != .None {
		return "", .Gate_Failed
	}
	typed, type_err := stage_typecheck_indexed(ast, index)
	if type_err != .None {
		return "", .Typecheck_Failed
	}
	if stage_contracts(typed).err != .None {
		return "", .Contract_Failed
	}
	verdict := stage_flatten(typed)
	if verdict.err != .None {
		return "", .Flatten_Failed
	}
	entrypoints, ep_err := parse_entrypoints_fcfg(entrypoint_fcfg)
	if ep_err != .None {
		return "", .Entrypoint_Failed
	}
	if validate_entrypoints(entrypoints, ast) != .None {
		return "", .Entrypoint_Failed
	}
	entrypoint, sel_err := select_entrypoint(entrypoints)
	if sel_err != .None {
		return "", .Entrypoint_Failed
	}
	whole_module_consts := collect_whole_module_const_records(ast, module_asts)
	if lower_verdict := lower_whole_module_refs(&ast, module_asts); lower_verdict.err != .None {
		return "", .Whole_Module_Collision
	}
	imported_fns := collect_imported_fn_records(ast, module_asts)
	imported_fns = concat_function_records(imported_fns, whole_module_consts)
	input := Emit_Input {
		ast            = ast,
		typed          = typed,
		flat           = verdict.flat,
		module         = module,
		project        = project,
		entrypoint     = entrypoint,
		imported_fns   = imported_fns,
		imported_decls = collect_imported_decls(ast, module_asts),
		tilemaps       = tilemaps,
		nav_graphs     = nav_graphs,
		level_spawns   = level_spawns,
		assets         = assets,
	}
	return emit_artifact(input, allocator)
}

emit_artifact :: proc(input: Emit_Input, allocator := context.allocator) -> (artifact: string, err: Emit_Error) {
	b := strings.builder_make(allocator)
	emit_line(&b, ARTIFACT_MAGIC, " ", encode_int(ARTIFACT_SCHEMA_VERSION, context.temp_allocator))

	emit_meta(&b, input.project)
	emit_enums(&b, input.ast, input.imported_decls.enums)
	emit_data(&b, input.ast, input.imported_decls)
	emit_signals(&b, input.ast, input.imported_decls.signals)
	emit_things(&b, input.ast, input.imported_decls.things)
	emit_functions(&b, input.ast, input.module, input.imported_fns)
	emit_behaviors(&b, input.ast, input.flat)
	emit_pipeline_flattened(&b, input.flat)
	emit_signal_routing(&b, input.flat)
	if setup_err := emit_setup(&b, setup_eval_ctx(input), input.level_spawns, input.imported_decls.things);
	   setup_err != .None {
		return "", setup_err
	}
	emit_bindings(&b, input.ast)
	emit_entrypoint(&b, input.entrypoint)
	emit_queries(&b, input.ast, input.module)
	emit_tilemaps(&b, input.tilemaps)
	emit_navs(&b, input.nav_graphs)
	emit_assets(&b, input.assets)
	emit_probes(&b, input.ast)

	return strings.to_string(b), .None
}

setup_eval_ctx :: proc(input: Emit_Input) -> Eval_Ctx {
	visit := new(Const_Visit, context.temp_allocator)
	visit.active = make(map[string]bool, context.temp_allocator)
	return Eval_Ctx {
		ast      = input.typed.ast,
		env      = input.typed.env,
		bindings = input.typed.bindings,
		modules  = nil,
		module   = input.module,
		visiting = visit,
	}
}

emit_line :: proc(b: ^strings.Builder, parts: ..string) {
	for part in parts {
		strings.write_string(b, part)
	}
	strings.write_byte(b, '\n')
}

emit_header :: proc(b: ^strings.Builder, name: string, count: int) {
	strings.write_byte(b, '[')
	strings.write_string(b, name)
	strings.write_byte(b, ' ')
	strings.write_int(b, count)
	emit_line(b, "]")
}
