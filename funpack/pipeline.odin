// The funpack test stage pipeline: lex → parse → typecheck → evaluate →
// report. Each stage is owned by its own file (lexer.odin, parser.odin,
// typecheck.odin, evaluate.odin); this file owns the pipeline-level
// types and the driver that threads a source string through the seams.
package funpack

Ast :: struct {
	tests: []Test_Node,
}

Typed_Ast :: struct {
	ast: Ast,
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
// a failed test.
Pipeline_Error :: enum {
	None,
	Parse_Failed,
	Typecheck_Failed,
}

run_test_pipeline :: proc(source: string) -> (report: Test_Report, err: Pipeline_Error) {
	tokens := stage_lex(source)
	ast, parse_err := stage_parse(tokens)
	if parse_err != .None {
		return Test_Report{}, .Parse_Failed
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
