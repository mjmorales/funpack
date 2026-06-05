// The funpack test stage pipeline: lex → parse → gates → typecheck →
// evaluate → report. Each stage is owned by its own file (lexer.odin,
// parser.odin, gates.odin, typecheck.odin, evaluate.odin); this file owns
// the pipeline-level types and the driver that threads a source string
// through the seams.
package funpack

// Ast is the parsed module: the file-leading @doc, the imports, the §06/§07
// top-level declarations the golden pong surface exercises, and the test
// blocks. The declaration slices are parse-only — no name resolution and
// no typing live here (those are sibling stages); this struct just carries
// every top-level node stage_parse recognized, in source order within each
// kind.
Ast :: struct {
	module_doc: string,
	imports:    []Import_Node,
	lets:       []Let_Decl_Node, // module-level `let NAME: T = expr` constants
	datas:      []Data_Node,     // `data Name { … }` value records
	enums:      []Enum_Node,     // `enum Name { … }`, incl. the `Name: Kind` role form
	things:     []Thing_Node,    // `thing`/`singleton Name { … }` entities
	signals:    []Signal_Node,   // `signal Name { … }` message values
	fns:        []Fn_Node,       // top-level `fn name(…) -> R { … }`
	behaviors:  []Behavior_Node, // `behavior name on Thing { fn step(…) … }`
	pipelines:  []Pipeline_Node, // `pipeline Name { stage: [behaviors] … }`
	tests:      []Test_Node,
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
// violation is a distinct compile error from a parse or typecheck failure.
Pipeline_Error :: enum {
	None,
	Parse_Failed,
	Gate_Failed,
	Typecheck_Failed,
}

run_test_pipeline :: proc(source: string) -> (report: Test_Report, err: Pipeline_Error) {
	tokens := stage_lex(source)
	ast, parse_err := stage_parse(tokens)
	if parse_err != .None {
		return Test_Report{}, .Parse_Failed
	}
	gate_err := stage_gates(ast)
	if gate_err != .None {
		return Test_Report{}, .Gate_Failed
	}
	typed, type_err := stage_typecheck(ast)
	if type_err != .None {
		return Test_Report{}, .Typecheck_Failed
	}
	result := stage_evaluate(typed)
	return stage_report(result), .None
}

stage_report :: proc(result: Eval_Result) -> Test_Report {
	exit_code := 0 if result.failed == 0 else 1
	return Test_Report{passed = result.passed, failed = result.failed, exit_code = exit_code}
}
