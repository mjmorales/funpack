// The funpack test stage pipeline: lex → parse → typecheck → evaluate →
// report. Every stage body is a deliberate typed stub: the seams keep the
// pipeline runnable end-to-end so each stage can be implemented
// independently behind its signature without breaking the spine.
package funpack

Token :: struct {
	text: string,
}

Assert_Node :: struct {
	source: string,
}

Ast :: struct {
	asserts: []Assert_Node,
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

run_test_pipeline :: proc() -> Test_Report {
	tokens := stage_lex("")
	ast := stage_parse(tokens)
	typed := stage_typecheck(ast)
	result := stage_evaluate(typed)
	return stage_report(result)
}

stage_lex :: proc(source: string) -> []Token {
	return nil
}

stage_parse :: proc(tokens: []Token) -> Ast {
	return Ast{}
}

stage_typecheck :: proc(ast: Ast) -> Typed_Ast {
	return Typed_Ast{ast = ast}
}

stage_evaluate :: proc(typed: Typed_Ast) -> Eval_Result {
	return Eval_Result{}
}

stage_report :: proc(result: Eval_Result) -> Test_Report {
	exit_code := 0 if result.failed == 0 else 1
	return Test_Report{passed = result.passed, failed = result.failed, exit_code = exit_code}
}
