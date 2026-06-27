package funpack

import "core:os"

Ast :: struct {
	module_doc: string,
	imports:    []Import_Node,
	decls:      []Decl_Ref,
	lets:       []Let_Decl_Node,
	datas:      []Data_Node,
	enums:      []Enum_Node,
	things:     []Thing_Node,
	signals:    []Signal_Node,
	fns:        []Fn_Node,
	queries:    []Query_Node,
	behaviors:  []Behavior_Node,
	pipelines:  []Pipeline_Node,
	tests:      []Test_Node,
	extern_types: []Extern_Type_Node,
}

Ast_Decl_Kind :: enum {
	Let,
	Data,
	Enum,
	Thing,
	Signal,
	Fn,
	Query,
	Behavior,
	Pipeline,
	Test,
	Extern_Type,
}

Decl_Ref :: struct {
	kind:  Ast_Decl_Kind,
	index: int,
}

Typed_Ast :: struct {
	ast:      Ast,
	bindings: Bindings,
	env:      Type_Env,
}

Eval_Result :: struct {
	passed:   int,
	failed:   int,
	failures: []Assert_Failure,
}

Assert_Failure :: struct {
	test_name:    string,
	line:         int,
	expr_text:    string,
	op:           string,
	lhs_display:  string,
	rhs_display:  string,
	has_operands: bool,
	path:         string,
}

Test_Report :: struct {
	passed:    int,
	failed:    int,
	exit_code: int,
	failures:  []Assert_Failure,
}

Pipeline_Error :: enum {
	None,
	Parse_Failed,
	Gate_Failed,
	Typecheck_Failed,
	Contract_Failed,
	Closure_Failed,
}

run_test_pipeline :: proc(source: string) -> (report: Test_Report, err: Pipeline_Error) {
	return run_module_pipeline(source, Module_Index{})
}

run_module_pipeline_named :: proc(
	source: string,
	index: Module_Index,
	modules: []Module_Eval,
	module: string,
	importer_root := "",
) -> (
	report: Test_Report,
	err: Pipeline_Error,
) {
	report, err, _ = run_module_pipeline_diag(source, index, modules, module, importer_root)
	return report, err
}

run_module_pipeline_diag :: proc(
	source: string,
	index: Module_Index,
	modules: []Module_Eval,
	module: string,
	importer_root := "",
) -> (
	report: Test_Report,
	err: Pipeline_Error,
	diag: Diagnostic,
) {
	tokens := stage_lex(source)
	ast, parse_verdict := stage_parse_located(tokens)
	if parse_verdict.err != .None {
		return Test_Report{}, .Parse_Failed, parse_diagnostic(parse_verdict.err, parse_verdict.line, parse_verdict.col)
	}
	if verdict := gate_verdict(ast); verdict.err != .None {
		return Test_Report{}, .Gate_Failed, gate_diagnostic(verdict.err, verdict.line, verdict.declaration, verdict.nesting_cause)
	}
	typed, type_verdict := stage_typecheck_located(ast, index, importer_root)
	if type_verdict.err != .None {
		return Test_Report{}, .Typecheck_Failed, type_diagnostic(type_verdict.err, type_verdict.line, type_verdict.col, type_verdict.declaration, type_verdict.hint)
	}
	if verdict := stage_contracts(typed); verdict.err != .None {
		line := verdict.line if verdict.line != 0 else behavior_decl_line(typed.ast, verdict.behavior)
		return Test_Report{}, .Contract_Failed, contract_diagnostic(verdict.err, line, verdict.behavior)
	}
	if verdict := stage_flatten(typed); verdict.err != .None {
		offender := flatten_offender_name(verdict)
		line := flatten_offender_line(typed.ast, verdict)
		return Test_Report{}, .Closure_Failed, flatten_diagnostic(verdict.err, line, offender)
	}
	result := stage_evaluate_indexed(typed, modules, module)
	return stage_report(result), .None, Diagnostic{}
}

behavior_decl_line :: proc(ast: Ast, name: string) -> int {
	for behavior in ast.behaviors {
		if behavior.name == name {
			return behavior.line
		}
	}
	return 0
}

flatten_offender_name :: proc(verdict: Flatten_Verdict) -> string {
	if verdict.err == .Unclosed_Signal {
		return verdict.signal
	}
	return ""
}

flatten_offender_line :: proc(ast: Ast, verdict: Flatten_Verdict) -> int {
	if verdict.err == .Unclosed_Signal {
		for signal in ast.signals {
			if signal.name == verdict.signal {
				return signal.line
			}
		}
		return 0
	}
	if len(ast.pipelines) > 0 {
		return ast.pipelines[0].line
	}
	return 0
}

run_module_pipeline :: proc(source: string, index: Module_Index) -> (report: Test_Report, err: Pipeline_Error) {
	return run_module_pipeline_evaled(source, index, nil)
}

run_module_pipeline_evaled :: proc(source: string, index: Module_Index, modules: []Module_Eval) -> (report: Test_Report, err: Pipeline_Error) {
	return run_module_pipeline_named(source, index, modules, "")
}

Project_Pipeline_Error :: enum {
	None,
	Index_Failed,
}

Project_Report :: struct {
	passed:        int,
	failed:        int,
	module_err:    Pipeline_Error,
	failed_path:   string,
	index_err:     Project_Pipeline_Error,
	diagnostic:    Diagnostic,
	failures:      []Assert_Failure,
}

project_pipeline_sources :: proc(project: Project) -> []Source {
	if len(project.package_sources) == 0 {
		return project.sources
	}
	combined := make([]Source, len(project.sources) + len(project.package_sources), context.temp_allocator)
	copy(combined[:len(project.sources)], project.sources)
	copy(combined[len(project.sources):], project.package_sources)
	return combined
}

run_project_pipeline :: proc(sources: []Source) -> Project_Report {
	modules := make([]string, len(sources), context.temp_allocator)
	asts := make([]Ast, len(sources), context.temp_allocator)
	source_texts := make([]string, len(sources), context.temp_allocator)
	package_roots := make([]string, len(sources), context.temp_allocator)
	for source, i in sources {
		bytes, read_err := os.read_entire_file_from_path(source.path, context.temp_allocator)
		if read_err != nil {
			return Project_Report{index_err = .Index_Failed, failed_path = source.path}
		}
		ast, parse_verdict := stage_parse_located(stage_lex(string(bytes)))
		if parse_verdict.err != .None {
			diag := parse_diagnostic(parse_verdict.err, parse_verdict.line, parse_verdict.col)
			diag.path = source.path
			return Project_Report{module_err = .Parse_Failed, failed_path = source.path, diagnostic = diag}
		}
		modules[i] = source.module
		asts[i] = ast
		source_texts[i] = string(bytes)
		package_roots[i] = source.package_root
	}

	index := build_module_index_typed(modules, asts, package_roots)
	eval_modules := build_module_eval_surface(modules, asts, index, package_roots)

	report := Project_Report{}
	failures := make([dynamic]Assert_Failure, 0, 0, context.temp_allocator)
	for source, i in sources {
		module_report, err, diag := run_module_pipeline_diag(source_texts[i], index, eval_modules, source.module, source.package_root)
		if err != .None {
			diag.path = source.path
			report.module_err = err
			report.failed_path = source.path
			report.diagnostic = diag
			return report
		}
		report.passed += module_report.passed
		report.failed += module_report.failed
		for failure in module_report.failures {
			stamped := failure
			stamped.path = source.path
			append(&failures, stamped)
		}
	}
	report.failures = failures[:]
	return report
}

build_module_eval_surface :: proc(modules: []string, asts: []Ast, index: Module_Index, package_roots: []string = nil) -> []Module_Eval {
	entries := make([]Module_Eval, len(asts), context.temp_allocator)
	for ast, i in asts {
		entries[i] = Module_Eval{module = modules[i], ast = ast}
		root := package_roots[i] if package_roots != nil else ""
		bindings, bind_err := resolve_imports_indexed(ast, index, root)
		if bind_err != .None {
			continue
		}
		env, env_err := resolve_env(ast, bindings, index)
		if env_err != .None {
			continue
		}
		entries[i].env = env
		entries[i].bindings = bindings
	}
	for i in 0 ..< len(entries) {
		entries[i].modules = entries
	}
	return entries
}

stage_report :: proc(result: Eval_Result) -> Test_Report {
	exit_code := 0 if result.failed == 0 else 1
	return Test_Report {
		passed = result.passed,
		failed = result.failed,
		exit_code = exit_code,
		failures = result.failures,
	}
}
