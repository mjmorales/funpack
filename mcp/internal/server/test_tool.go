package server

import (
	"context"
	"regexp"
	"strconv"

	"github.com/mjmorales/funpack/mcp/internal/funpack"
	"github.com/mjmorales/funpack/mcp/internal/funpackexec"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// TestInput drives `funpack test` against the project tree at Dir — every test
// block in the §14 tree runs through one project-wide pipeline. Dir is required:
// funpack has no project-path flag, so the tool points funpack at a project by
// running it with that working directory.
type TestInput struct {
	Dir string `json:"dir" jsonschema:"absolute path to the funpack project tree to test (funpack runs every test block in the tree at this working directory)"`
}

// TestFailure is one failed assertion, parsed from funpack's per-failure stderr
// block. Name is the test block's name and Message is the assertion-failure
// detail (the file:line, the failing expression, and the evaluated operands when
// funpack rendered them). A failure funpack emitted in a shape the parser does
// not recognize contributes to Failed/Total via the count line but yields no
// TestFailure entry — Raw still carries funpack's full output verbatim.
type TestFailure struct {
	Name    string `json:"name" jsonschema:"the failing test block's name"`
	Message string `json:"message" jsonschema:"the assertion-failure detail funpack rendered (location, expression, and evaluated operands when available)"`
}

// TestOutput is the structured summary of one `funpack test` run. Ok is the
// at-a-glance pass/fail the agent branches on (ExitCode == 0). Passed/Failed/Total
// are parsed from funpack's `N passed, M failed` summary line; Failures lifts each
// per-failure block into a name+message pair. ExitCode is funpack's own code
// (0 all-pass, 1 assertions failed, 2 compile/tree error). Raw is funpack's full
// output (stdout then stderr) verbatim, the source of truth the agent falls back
// to when the structured fields cannot capture the outcome (a compile error emits
// no count line, so Passed/Failed/Total stay zero and the diagnostic lives only in
// Raw).
type TestOutput struct {
	Ok       bool          `json:"ok" jsonschema:"true when ExitCode is zero — every test block passed"`
	Passed   int           `json:"passed" jsonschema:"count of passing assertions from funpack's summary line; zero when no summary line was emitted (a compile/tree error)"`
	Failed   int           `json:"failed" jsonschema:"count of failing assertions from funpack's summary line; zero when no summary line was emitted"`
	Total    int           `json:"total" jsonschema:"Passed + Failed; the asserted count funpack ran"`
	Failures []TestFailure `json:"failures" jsonschema:"the parsed per-failure blocks; empty on an all-pass run or a compile/tree error that emitted no failure blocks"`
	ExitCode int           `json:"exit_code" jsonschema:"funpack's exit code: 0 all-pass, 1 assertions failed, 2 a malformed tree or compile error"`
	Raw      string        `json:"raw" jsonschema:"funpack's full output verbatim (stdout then stderr) — the fallback when the structured fields cannot capture the outcome, e.g. a compile error's diagnostic"`
}

// summaryLineRE matches funpack's authoritative summary line, emitted on stdout
// for any run whose pipeline completed (exit 0 or 1):
//
//	funpack test: <P> passed, <F> failed
//
// A compile error or malformed tree (exit 2) emits no such line — only a stderr
// diagnostic — so a non-match leaves the counts at zero and the diagnostic in Raw.
// Mirrors run_test_verb's `fmt.printfln("funpack test: %d passed, %d failed", ...)`.
var summaryLineRE = regexp.MustCompile(`funpack test: (\d+) passed, (\d+) failed`)

// failureLineRE matches one funpack per-failure header, emitted on stderr for each
// failed assertion (exit 1):
//
//	funpack test: <path>:<line>: assertion failed (<test name>): <expr>
//
// Capture groups: 1 = the whole rendered detail (everything after the
// `funpack test: ` prefix — location, the literal "assertion failed", the
// parenthesized name, and the failing expression), preserved as Message so the
// agent reads funpack's own phrasing verbatim; 2 = the test block name lifted out
// of the parentheses. Mirrors render_assert_failure's
// `<path>:<line>: assertion failed (<test_name>): <expr_text>` header. The header
// alone is matched; funpack's following excerpt/operand gutter lines belong to the
// same failure and are not separate headers (each begins with leading whitespace,
// never the `funpack test: ` prefix), so they do not produce spurious entries.
var failureLineRE = regexp.MustCompile(`funpack test: (.+?: assertion failed \(([^)]*)\): .+)`)

// registerTestTool wires the test tool: it runs `funpack test` in the requested
// project directory and parses funpack's own output into a structured pass/fail
// summary. A missing dir or a resolve/spawn failure is a tool error the agent
// reads and self-corrects from; a failing test suite (funpack exit 1) is a NORMAL
// result with Ok false — the agent branches on the counts and the parsed failures.
func registerTestTool(srv *mcp.Server, logger zerolog.Logger) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "test",
		Description: "Run every test block in the funpack project at the given directory and return a structured pass/fail summary (counts plus each failing test's name and detail).",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in TestInput) (*mcp.CallToolResult, TestOutput, error) {
		if in.Dir == "" {
			res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategoryInvalidInput, "test: dir is required (path to the funpack project tree)"))
			return res, TestOutput{}, protoErr
		}

		bin, err := funpack.Resolve()
		if err != nil {
			logger.Debug().Err(err).Msg("funpack resolve failed")
			res, protoErr := mcperr.ToolError(err)
			return res, TestOutput{}, protoErr
		}

		out, err := funpackexec.RunInDir(ctx, in.Dir, bin, "test")
		if err != nil {
			logger.Debug().Str("dir", in.Dir).Err(err).Msg("funpack test exec failed")
			res, protoErr := mcperr.ToolError(err)
			return res, TestOutput{}, protoErr
		}

		summary := parseTestOutput(out)
		logger.Debug().
			Str("dir", in.Dir).
			Int("exit_code", summary.ExitCode).
			Int("passed", summary.Passed).
			Int("failed", summary.Failed).
			Msg("funpack test complete")
		return nil, summary, nil
	})
}

// parseTestOutput turns funpack's captured streams into a TestOutput. Ok mirrors
// the exit code (0 == every test passed). The summary counts come from stdout's
// `N passed, M failed` line; the per-failure blocks come from stderr. Raw carries
// stdout then stderr verbatim so a caller always has funpack's full diagnostics —
// the parse is additive, never lossy. Parse limit: a compile error or malformed
// tree (exit 2) emits no summary line, so Passed/Failed/Total stay zero and the
// diagnostic is recoverable only from Raw; the structured counts describe an
// assertion run, not a compilation failure.
func parseTestOutput(res funpackexec.Result) TestOutput {
	out := TestOutput{
		ExitCode: res.ExitCode,
		Ok:       res.ExitCode == 0,
		Raw:      joinStreams(res.Stdout, res.Stderr),
		Failures: []TestFailure{},
	}

	// The summary line is funpack's authoritative count. It rides stdout, but scan
	// the joined output so a future stream-merge cannot drop it.
	if m := summaryLineRE.FindStringSubmatch(out.Raw); m != nil {
		// The regex's \d+ groups are guaranteed numeric, so Atoi cannot fail; the
		// error is discarded deliberately rather than threaded through a parse that
		// already pattern-matched the digits.
		out.Passed, _ = strconv.Atoi(m[1])
		out.Failed, _ = strconv.Atoi(m[2])
		out.Total = out.Passed + out.Failed
	}

	for _, m := range failureLineRE.FindAllStringSubmatch(out.Raw, -1) {
		out.Failures = append(out.Failures, TestFailure{
			Name:    m[2],
			Message: m[1],
		})
	}

	return out
}

// joinStreams concatenates stdout and stderr into the single Raw passthrough,
// separating them with a newline only when both are non-empty so the boundary
// never injects a spurious blank line.
func joinStreams(stdout, stderr string) string {
	switch {
	case stdout == "":
		return stderr
	case stderr == "":
		return stdout
	default:
		return stdout + "\n" + stderr
	}
}
