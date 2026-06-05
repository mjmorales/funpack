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
	if verdict := stage_contracts(typed); verdict.err != .None {
		return Test_Report{}, .Contract_Failed
	}
	if verdict := stage_flatten(typed); verdict.err != .None {
		return Test_Report{}, .Closure_Failed
	}
	result := stage_evaluate(typed)
	return stage_report(result), .None
}

stage_report :: proc(result: Eval_Result) -> Test_Report {
	exit_code := 0 if result.failed == 0 else 1
	return Test_Report{passed = result.passed, failed = result.failed, exit_code = exit_code}
}
