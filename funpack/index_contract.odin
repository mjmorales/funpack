package funpack

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

INDEX_SCHEMA_VERSION :: 6

Index_Decl_Kind :: enum {
	Data,
	Enum,
	Thing,
	Signal,
	Fn,
	Extern_Fn,
	Query,
	Behavior,
	Pipeline,
	Let,
	Test,
	Extern_Type,
}

Decl_Record :: struct {
	schema_version: int,
	qualified_name: string,
	kind:           Index_Decl_Kind,
	file:           string,
	span:           int,
	doc:            string,
	gtags:          []string,
	stub:           bool,
	todo:           bool,
	debug:          []string,
	exposed:        bool,
	emits:          []string,
	consumes:       []string,
	calls:          []string,
	dup_class:      u64,
	mut_data:       []string,
}

emit_decl_record :: proc(record: Decl_Record, allocator := context.allocator) -> string {
	bytes, _ := json.marshal(record, {use_enum_names = true}, context.temp_allocator)
	line := strings.concatenate({string(bytes), "\n"}, allocator)
	return line
}

Entrypoint_Record :: struct {
	name:     string,
	pipeline: string,
	tick_hz:  int,
	bindings: string,
}

Build_Record :: struct {
	name:     string,
	platform: string,
}

Capability :: enum {
	Render,
	Input,
	State,
	Ui,
	Modeling,
	Netcode,
	Modding,
	Audio,
}

Gate_Family :: enum {
	Cyclomatic,
	Nesting,
	Fn_Size,
	Arity,
	Exhaustiveness,
	Duplication,
	Effect_Closure,
}

Gate_Result :: struct {
	gate:   Gate_Family,
	passed: bool,
}

Flat_Step_Record :: struct {
	ordinal:  int,
	stage:    string,
	behavior: string,
}

Project_Record :: struct {
	schema_version:     int,
	entrypoints:        []Entrypoint_Record,
	builds:             []Build_Record,
	tag_registry:       []string,
	capabilities:       []Capability,
	pipeline_flattened: []Flat_Step_Record,
	gate_results:       []Gate_Result,
}

Index_Contract_Error :: enum {
	None,
	Missing_Configs_Dir,
	Malformed_Entrypoints,
	Malformed_Builds,
	Project_Read_Failed,
}

build_project_record :: proc(
	root: string,
	typed: Typed_Ast,
	flat: Flattened_Pipeline,
) -> (record: Project_Record, err: Index_Contract_Error) {
	configs_dir, _ := filepath.join({root, "funpack_configs"}, context.temp_allocator)
	if !os.is_dir(configs_dir) {
		return Project_Record{}, .Missing_Configs_Dir
	}
	entrypoints, entry_err := read_entrypoints(configs_dir)
	if entry_err != .None {
		return Project_Record{}, entry_err
	}
	builds, build_err := read_builds(configs_dir)
	if build_err != .None {
		return Project_Record{}, build_err
	}
	return Project_Record {
			schema_version     = INDEX_SCHEMA_VERSION,
			entrypoints        = entrypoints,
			builds             = builds,
			tag_registry       = read_tag_registry(configs_dir),
			capabilities       = derive_capabilities(root, typed, entrypoints),
			pipeline_flattened = flatten_to_records(flat),
			gate_results       = derive_gate_results(typed, flat),
		},
		.None
}

emit_project_record :: proc(record: Project_Record, allocator := context.allocator) -> string {
	bytes, _ := json.marshal(record, {use_enum_names = true}, context.temp_allocator)
	line := strings.concatenate({string(bytes), "\n"}, allocator)
	return line
}

flatten_to_records :: proc(flat: Flattened_Pipeline) -> []Flat_Step_Record {
	steps := make([]Flat_Step_Record, len(flat.order), context.temp_allocator)
	for step, i in flat.order {
		steps[i] = Flat_Step_Record{ordinal = step.ordinal, stage = step.stage, behavior = step.behavior}
	}
	return steps
}

derive_gate_results :: proc(typed: Typed_Ast, flat: Flattened_Pipeline) -> []Gate_Result {
	units := gate_units(typed.ast)
	sets := closed_variant_sets(typed.ast)
	results := make([]Gate_Result, len(Gate_Family), context.temp_allocator)
	results[Gate_Family.Cyclomatic]     = Gate_Result{gate = .Cyclomatic, passed = !any_unit_fails(units, check_cyclomatic)}
	results[Gate_Family.Nesting]        = Gate_Result{gate = .Nesting, passed = !any_unit_fails(units, check_nesting_err)}
	results[Gate_Family.Fn_Size]        = Gate_Result{gate = .Fn_Size, passed = !any_unit_fails(units, check_fn_size)}
	results[Gate_Family.Arity]          = Gate_Result{gate = .Arity, passed = !any_unit_fails(units, gate_arity_unit)}
	results[Gate_Family.Exhaustiveness] = Gate_Result{gate = .Exhaustiveness, passed = !any_match_fails(units, sets)}
	dup_err, _, _ := gate_duplication(units)
	results[Gate_Family.Duplication]    = Gate_Result{gate = .Duplication, passed = dup_err == .None}
	results[Gate_Family.Effect_Closure] = Gate_Result{gate = .Effect_Closure, passed = !first_unclosed_holds(flat.routes)}
	return results
}

check_fn_size :: proc(unit: Gate_Unit) -> Gate_Error {
	if len(statements_count(unit.body)) > MAX_FN_STATEMENTS {
		return .Fn_Size_Exceeded
	}
	return .None
}

check_nesting_err :: proc(unit: Gate_Unit) -> Gate_Error {
	err, _ := check_nesting(unit)
	return err
}

any_unit_fails :: proc(units: []Gate_Unit, check: proc(Gate_Unit) -> Gate_Error) -> bool {
	for unit in units {
		if check(unit) != .None {
			return true
		}
	}
	return false
}

any_match_fails :: proc(units: []Gate_Unit, sets: []Closed_Variant_Set) -> bool {
	for unit in units {
		if check_match_exhaustiveness_unit(unit, sets) != .None {
			return true
		}
	}
	return false
}

first_unclosed_holds :: proc(routes: []Signal_Route) -> bool {
	_, unclosed := first_unclosed(routes)
	return unclosed
}

derive_capabilities :: proc(root: string, typed: Typed_Ast, entrypoints: []Entrypoint_Record) -> []Capability {
	caps := make([dynamic]Capability, 0, len(Capability), context.temp_allocator)
	append(&caps, Capability.Render, Capability.Input, Capability.State)
	if dir_is_non_empty(root, "ui") {
		append(&caps, Capability.Ui)
	}
	if dir_is_non_empty(root, "models") {
		append(&caps, Capability.Modeling)
	}
	if any_entrypoint_has_net(entrypoints) {
		append(&caps, Capability.Netcode)
	}
	if source_has_expose(typed.ast) {
		append(&caps, Capability.Modding)
	}
	if source_has_audio_stage(typed.ast) {
		append(&caps, Capability.Audio)
	}
	return caps[:]
}

dir_is_non_empty :: proc(root: string, sub: string) -> bool {
	dir, _ := filepath.join({root, sub}, context.temp_allocator)
	if !os.is_dir(dir) {
		return false
	}
	walker := os.walker_create(dir)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type == .Regular {
			return true
		}
	}
	return false
}

any_entrypoint_has_net :: proc(_: []Entrypoint_Record) -> bool {
	return false
}

source_has_expose :: proc(ast: Ast) -> bool {
	for ref in ast.decls {
		switch ref.kind {
		case .Data:
			if ast.datas[ref.index].exposed {
				return true
			}
		case .Enum:
			if ast.enums[ref.index].exposed {
				return true
			}
		case .Thing:
			if ast.things[ref.index].exposed {
				return true
			}
		case .Signal:
			if ast.signals[ref.index].exposed {
				return true
			}
		case .Fn:
			if ast.fns[ref.index].exposed {
				return true
			}
		case .Query:
			if ast.queries[ref.index].exposed {
				return true
			}
		case .Behavior:
			if ast.behaviors[ref.index].exposed {
				return true
			}
		case .Pipeline:
			if ast.pipelines[ref.index].exposed {
				return true
			}
		case .Let:
			if ast.lets[ref.index].exposed {
				return true
			}
		case .Test:
		case .Extern_Type:
			if ast.extern_types[ref.index].exposed {
				return true
			}
		}
	}
	return false
}

source_has_audio_stage :: proc(ast: Ast) -> bool {
	for pipeline in ast.pipelines {
		for stage in pipeline.stages {
			if stage.name == "audio" {
				return true
			}
		}
	}
	return false
}

read_entrypoints :: proc(configs_dir: string) -> (entrypoints: []Entrypoint_Record, err: Index_Contract_Error) {
	path, _ := filepath.join({configs_dir, "entrypoints.fcfg"}, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		return nil, .None
	}
	parsed, parse_err := parse_entrypoints_fcfg(string(bytes))
	if parse_err != .None {
		return nil, .Malformed_Entrypoints
	}
	records, ok := lift_entrypoint_records(parsed)
	if !ok {
		return nil, .Malformed_Entrypoints
	}
	return records, .None
}

lift_entrypoint_records :: proc(parsed: Entrypoints) -> (records: []Entrypoint_Record, ok: bool) {
	lifted := make([]Entrypoint_Record, len(parsed.entrypoints), context.temp_allocator)
	for block, i in parsed.entrypoints {
		hz, parsed_hz := parse_tick_hz(block.tick)
		if !parsed_hz {
			return nil, false
		}
		lifted[i] = Entrypoint_Record {
			name     = block.name,
			pipeline = block.pipeline,
			tick_hz  = hz,
			bindings = block.bindings,
		}
	}
	return lifted, true
}

read_builds :: proc(configs_dir: string) -> (builds: []Build_Record, err: Index_Contract_Error) {
	path, _ := filepath.join({configs_dir, "builds.fcfg"}, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		return nil, .None
	}
	records := make([dynamic]Build_Record, 0, 2, context.temp_allocator)
	blocks := fcfg_blocks(string(bytes), "build")
	for block in blocks {
		record := Build_Record{name = block.label}
		for assignment in block.assignments {
			if assignment.key == "platform" {
				record.platform = assignment.value
			}
		}
		if record.platform == "" {
			return nil, .Malformed_Builds
		}
		append(&records, record)
	}
	return records[:], .None
}

read_tag_registry :: proc(configs_dir: string) -> []string {
	path, _ := filepath.join({configs_dir, "tags.fcfg"}, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		return nil
	}
	return fcfg_tag_list(string(bytes))
}

Index_Module :: struct {
	module: string,
	typed:  Typed_Ast,
	flat:   Flattened_Pipeline,
}

read_index_project :: proc(
	root: string,
	allocator := context.allocator,
) -> (
	ndjson: string,
	err: Index_Contract_Error,
	project_err: Project_Error,
	compiled: bool,
) {
	identity, read_err, _ := read_project(root)
	if read_err != .None {
		return "", .Project_Read_Failed, read_err, false
	}
	if len(identity.sources) == 0 {
		return "", .None, .None, false
	}
	index_modules, ok := compile_index_modules(project_pipeline_sources(identity))
	if !ok {
		return "", .None, .None, false
	}
	if len(index_modules) == 1 {
		index_modules[0].module = ""
	}
	entrypoint := entrypoint_module_name(root)
	ordered := order_index_modules(index_modules, entrypoint)
	record_src := ordered[0]
	record, record_err := build_project_record(root, record_src.typed, record_src.flat)
	if record_err != .None {
		return "", record_err, .None, false
	}
	return emit_index_stream(record, ordered, allocator), .None, .None, true
}

compile_index_modules :: proc(sources: []Source) -> (modules: []Index_Module, ok: bool) {
	module_names := make([]string, len(sources), context.temp_allocator)
	asts := make([]Ast, len(sources), context.temp_allocator)
	package_roots := make([]string, len(sources), context.temp_allocator)
	for source, i in sources {
		bytes, read_err := os.read_entire_file_from_path(source.path, context.temp_allocator)
		if read_err != nil {
			return nil, false
		}
		ast, parse_err := stage_parse(stage_lex(string(bytes)))
		if parse_err != .None {
			return nil, false
		}
		module_names[i] = source.module
		asts[i] = ast
		package_roots[i] = source.package_root
	}
	index := build_module_index_typed(module_names, asts, package_roots)
	derived := make([]Index_Module, len(sources), context.temp_allocator)
	for ast, i in asts {
		typed, type_err := stage_typecheck_indexed(ast, index, sources[i].package_root)
		if type_err != .None {
			return nil, false
		}
		verdict := stage_flatten(typed)
		if verdict.err != .None {
			return nil, false
		}
		derived[i] = Index_Module{module = module_names[i], typed = typed, flat = verdict.flat}
	}
	return derived, true
}

order_index_modules :: proc(modules: []Index_Module, entrypoint: string) -> []Index_Module {
	names := make([]string, len(modules), context.temp_allocator)
	for m, i in modules {
		names[i] = m.module
	}
	ordered := make([]Index_Module, len(modules), context.temp_allocator)
	for src, dst in entrypoint_first_order(names, entrypoint) {
		ordered[dst] = modules[src]
	}
	return ordered
}

entrypoint_first_order :: proc(module_names: []string, entrypoint: string) -> []int {
	order := make([dynamic]int, 0, len(module_names), context.temp_allocator)
	if entrypoint != "" {
		for name, i in module_names {
			if name == entrypoint {
				append(&order, i)
				break
			}
		}
	}
	for name, i in module_names {
		if entrypoint != "" && name == entrypoint {
			continue
		}
		append(&order, i)
	}
	return order[:]
}

entrypoint_module_name :: proc(root: string) -> string {
	path, _ := filepath.join({root, "funpack_configs", "entrypoints.fcfg"}, context.temp_allocator)
	bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
	if read_err != nil {
		return ""
	}
	parsed, parse_err := parse_entrypoints_fcfg(string(bytes))
	if parse_err != .None {
		return ""
	}
	return parsed.use_module
}

emit_index_stream :: proc(
	record: Project_Record,
	modules: []Index_Module,
	allocator := context.allocator,
) -> string {
	lines := make([dynamic]string, 0, 1 + total_decl_count(modules), context.temp_allocator)
	append(&lines, emit_project_record(record, context.temp_allocator))
	for m in modules {
		decls := derive_decl_records(m.module, m.typed, m.flat)
		for decl in decls {
			append(&lines, emit_decl_record(decl, context.temp_allocator))
		}
	}
	return strings.concatenate(lines[:], allocator)
}

total_decl_count :: proc(modules: []Index_Module) -> int {
	total := 0
	for m in modules {
		total += len(m.typed.ast.decls)
	}
	return total
}

compile_for_index :: proc(source: string) -> (typed: Typed_Ast, flat: Flattened_Pipeline, compiled: bool) {
	ast, parse_err := stage_parse(stage_lex(source))
	if parse_err != .None {
		return Typed_Ast{}, Flattened_Pipeline{}, false
	}
	typed_ast, type_err := stage_typecheck(ast)
	if type_err != .None {
		return Typed_Ast{}, Flattened_Pipeline{}, false
	}
	verdict := stage_flatten(typed_ast)
	if verdict.err != .None {
		return Typed_Ast{}, Flattened_Pipeline{}, false
	}
	return typed_ast, verdict.flat, true
}

index_capabilities_contains :: proc(caps: []Capability, cap: Capability) -> bool {
	return slice.contains(caps, cap)
}
