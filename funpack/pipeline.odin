// The funpack test stage pipeline: lex → parse → gates → typecheck →
// contracts → flatten → evaluate → report. Each stage is owned by its own
// file (lexer.odin, parser.odin, gates.odin, typecheck.odin, contracts.odin,
// pipeline_flatten.odin, evaluate.odin); this file owns the pipeline-level
// types and the driver that threads a source string through the seams. The
// contracts stage is the §06 §6 behavior-contract NODE check — it reads the
// typed signatures, so it follows typecheck. The flatten stage is the §07 §3
// depth-first flatten plus the §04 §4 / §07 §2 effect-closure EDGE check; it
// reads the typed signatures over the flattened total order, so it follows
// the node check. A closure failure is a compile error, never a counted test
// failure, so it gates evaluation like every prior stage.
package funpack

import "core:os"

// Ast is the parsed module: the file-leading @doc, the imports, the §06/§07
// top-level declarations the golden pong surface exercises, and the test
// blocks. The declaration slices are parse-only — no name resolution and
// no typing live here (those are sibling stages); this struct carries
// every top-level node stage_parse recognized. Each per-kind slice keeps
// source order within its kind (the storage every kind-scoped consumer
// reads), and `decls` is the SOURCE-ORDERED declaration sequence across
// kinds — the parser appends one Decl_Ref per declaration in parse order,
// so the author's cross-kind interleaving survives the parse. Every
// order-observable consumer (render_canonical, the index derivation, the
// gate walks, the release hole/debug walkers) reads through `decls`, so
// the formatter, the Index Contract, and the release refusals can never
// disagree on declaration order (ADR
// 2026-06-10-formatter-canon-source-ordered-declarations).
Ast :: struct {
	module_doc: string,
	imports:    []Import_Node,
	decls:      []Decl_Ref,      // source-ordered declaration sequence across kinds
	lets:       []Let_Decl_Node, // module-level `let NAME: T = expr` constants
	datas:      []Data_Node,     // `data Name { … }` value records
	enums:      []Enum_Node,     // `enum Name { … }`, incl. the `Name: Kind` role form
	things:     []Thing_Node,    // `thing`/`singleton Name { … }` entities
	signals:    []Signal_Node,   // `signal Name { … }` message values
	fns:        []Fn_Node,       // top-level `fn name(…) -> R { … }`
	queries:    []Query_Node,    // `query name(…) -> R { … }` §08 §3 read-only declarations
	behaviors:  []Behavior_Node, // `behavior name on Thing { fn step(…) … }`
	pipelines:  []Pipeline_Node, // `pipeline Name { stage: [behaviors] … }`
	tests:      []Test_Node,
	extern_types: []Extern_Type_Node, // `extern type Name` §26 §2 opaque native types
}

// Ast_Decl_Kind names one top-level declaration kind — the closed tag a Decl_Ref
// carries to select the Ast per-kind slice its declaration lives in. Imports
// are the module header, not declarations, so they have no kind here.
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
	Extern_Type, // `extern type Name` (§26 §2) — an extern FN rides .Fn via Fn_Node.is_extern
}

// Decl_Ref locates one declaration in the Ast: kind selects the per-kind
// slice, index the node within it. The Ast's `decls` sequence is a slice of
// these in parse order — a reference layer over the kind slices, so the
// nodes themselves are stored once and kind-scoped consumers keep their
// direct per-kind reads.
Decl_Ref :: struct {
	kind:  Ast_Decl_Kind,
	index: int,
}

Typed_Ast :: struct {
	ast:      Ast,
	bindings: Bindings, // imported-name resolutions (surface.odin)
	env:      Type_Env, // resolved user-declaration environment (resolve.odin)
}

Eval_Result :: struct {
	passed: int,
	failed: int,
}

Test_Report :: struct {
	passed:    int,
	failed:    int,
	exit_code: int,
}

// Pipeline_Error distinguishes a source that failed to compile from a
// source whose assertions failed — a compile error is never counted as
// a failed test. Gate_Failed is its own arm so a structural-budget
// violation is a distinct compile error from a parse or typecheck failure;
// Contract_Failed is the §06 §6 behavior-contract node-check reject, a
// distinct compile error from a typecheck failure (it runs after typing,
// reading the typed signatures); Closure_Failed is the §04 §4 / §07 §2
// effect-closure (or flatten) reject, a distinct compile error from the
// node check (it runs over the flattened total order, downstream of it).
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

// run_module_pipeline_named is run_module_pipeline_evaled with the module's own §15
// name threaded through to the evaluator — the namespace half of an intra-module
// const's cycle key, so a self/mutual const cycle within THIS module is caught
// fail-closed by the evaluator's visited set. run_module_pipeline_evaled is the
// nameless projection (module = "") the single-source path keeps using.
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
	tokens := stage_lex(source)
	ast, parse_err := stage_parse(tokens)
	if parse_err != .None {
		return Test_Report{}, .Parse_Failed
	}
	gate_err := stage_gates(ast)
	if gate_err != .None {
		return Test_Report{}, .Gate_Failed
	}
	// importer_root is the module's own §30 package root ("" = a
	// consuming-project module), so a path-dependency's source — compiled
	// through the consumer's pipeline with the same gates (§30 §7) — types
	// from its own vantage.
	typed, type_err := stage_typecheck_indexed(ast, index, importer_root)
	if type_err != .None {
		return Test_Report{}, .Typecheck_Failed
	}
	if verdict := stage_contracts(typed); verdict.err != .None {
		return Test_Report{}, .Contract_Failed
	}
	if verdict := stage_flatten(typed); verdict.err != .None {
		return Test_Report{}, .Closure_Failed
	}
	result := stage_evaluate_indexed(typed, modules, module)
	return stage_report(result), .None
}

// run_module_pipeline threads one module's source through the stage pipeline
// against a project-wide module index, so a module importing a sibling user module
// (the arena seam, the arena schema) types cross-module. An empty index reduces it
// to the single-source run_test_pipeline — every user-module import is
// .Unknown_Module — so the all-OFF trees (pong/snake/numerics) are unchanged. The
// stage order is identical to the single-source path; only the typecheck stage
// becomes index-aware (stage_typecheck_indexed), and the downstream stages read
// the Typed_Ast unchanged (their cross-module names are already resolved into it).
run_module_pipeline :: proc(source: string, index: Module_Index) -> (report: Test_Report, err: Pipeline_Error) {
	return run_module_pipeline_evaled(source, index, nil)
}

// run_module_pipeline_evaled is run_module_pipeline plus a project-wide EVAL
// surface (one Module_Eval per sibling user module), so a test reaching a
// cross-module const (`assets.coin_sfx`) evaluates it in its owning module's
// environment. modules = nil reduces it to run_module_pipeline — the cross-module
// eval arm never fires — so the single-source and per-module typecheck paths are
// unchanged. Only the evaluate stage becomes eval-surface-aware; every prior stage
// is identical.
run_module_pipeline_evaled :: proc(source: string, index: Module_Index, modules: []Module_Eval) -> (report: Test_Report, err: Pipeline_Error) {
	return run_module_pipeline_named(source, index, modules, "")
}

// Project_Pipeline_Error is closed with the source-set staging error a multi-module
// run can hit BEFORE any module compiles: the project-wide index build itself can
// fail to read or parse a source. It composes with Pipeline_Error — Index_Failed
// is the index-build tier, then each module rides the per-module Pipeline_Error —
// so the test verb maps both to the §29 §3 exit-2 compile-error class.
Project_Pipeline_Error :: enum {
	None,
	Index_Failed,
}

// Project_Report is one multi-module run's outcome: the summed assertion counts
// across every module, the first module to hit a compile error (with its
// per-module Pipeline_Error and source path), and the index-build verdict. A
// compile error halts the run — a malformed module has no well-defined pipeline,
// so the §29 §3 all-or-nothing contract refuses the whole project rather than
// reporting a partial pass.
Project_Report :: struct {
	passed:        int,
	failed:        int,
	module_err:    Pipeline_Error,     // the first module's compile error (.None when every module compiled)
	failed_path:   string,             // the source path of module_err (when set)
	index_err:     Project_Pipeline_Error,
}

// project_pipeline_sources is the source set the test verb compiles: the
// project's own modules (src/ + gen/) followed by its §30 path-dependency
// modules (package_sources — prefixed, package_root stamped). The dependency
// rides the consumer's pipeline with the same gates as the consumer's own
// code (§30 §7), so both sets join ONE walk against ONE index; the project's
// own sources stay first, keeping their existing deterministic order, with
// each dep's sources following in declared-dep order.
project_pipeline_sources :: proc(project: Project) -> []Source {
	if len(project.package_sources) == 0 {
		return project.sources
	}
	combined := make([]Source, len(project.sources) + len(project.package_sources), context.temp_allocator)
	copy(combined[:len(project.sources)], project.sources)
	copy(combined[len(project.sources):], project.package_sources)
	return combined
}

// run_project_pipeline runs every source of a §14 project through the pipeline
// against ONE project-wide module index, so a multi-module project (the arena
// example: arena_world + the arena seam + arena_game) types end-to-end. It builds
// the typed index once (resolving each module's exported fn signatures, the
// cross-module call surface), then runs each source's pipeline against it,
// short-circuiting on the first module's compile error (a compile error is never a
// counted failure, §29 §3) and summing the assertion counts otherwise. A source
// the index cannot read or parse fails the build before any module compiles.
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
		ast, parse_err := stage_parse(stage_lex(string(bytes)))
		if parse_err != .None {
			return Project_Report{module_err = .Parse_Failed, failed_path = source.path}
		}
		modules[i] = source.module
		asts[i] = ast
		source_texts[i] = string(bytes)
		package_roots[i] = source.package_root
	}

	// The §30 package_roots ride in lockstep with the modules: a path
	// dependency's sources (read_project's package_sources, prefixed
	// `<name>.<module>`) stamp their entries' package_root so the §30 §6
	// expose gate and the §30 §2 star-graph refusal both see the edge.
	index := build_module_index_typed(modules, asts, package_roots)
	eval_modules := build_module_eval_surface(modules, asts, index, package_roots)

	report := Project_Report{}
	for source, i in sources {
		// The module's own §15 name threads to the evaluator so an intra-module
		// const cycle in THIS module keys on its module (and a cross-module cycle
		// shares the same visited set through the eval surface).
		module_report, err := run_module_pipeline_named(source_texts[i], index, eval_modules, source.module, source.package_root)
		if err != .None {
			report.module_err = err
			report.failed_path = source.path
			return report
		}
		report.passed += module_report.passed
		report.failed += module_report.failed
	}
	return report
}

// build_module_eval_surface resolves each module's (ast, env, bindings) against the
// project-wide typed index — the EVAL surface a cross-module const reference reads
// to evaluate a let initializer in its OWNING module's environment. It is the
// evaluation analogue of build_module_index_typed: the name+type index typed the
// cross-module reference, this carries the values behind it. A module whose own
// imports/env do not resolve gets an empty (ast, env, bindings) entry — its own
// per-module typecheck already failed the project, so the entry is never read. The
// shared eval_modules slice is back-referenced on every entry so a const RHS can
// itself reach a further sibling module.
// package_roots (lockstep with modules, nil = all within-project) threads each
// module's own §30 vantage so a package module's internal imports resolve here
// exactly as they did in its typecheck.
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
	// Back-reference the shared surface onto every entry so a cross-module const
	// whose initializer reaches a further sibling resolves through the same slice.
	for i in 0 ..< len(entries) {
		entries[i].modules = entries
	}
	return entries
}

stage_report :: proc(result: Eval_Result) -> Test_Report {
	exit_code := 0 if result.failed == 0 else 1
	return Test_Report{passed = result.passed, failed = result.failed, exit_code = exit_code}
}
