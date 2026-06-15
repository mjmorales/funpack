package server

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// The fake-funpack `test` payloads below are verbatim copies of real
// `funpack test` output observed on this machine, so the parser is tested against
// the exact byte shape funpack emits (see run_test_verb / render_assert_failure in
// funpack/main.odin and funpack/diagnostics.odin):
//
//   - the summary line `funpack test: N passed, M failed` rides stdout on any run
//     whose pipeline completed (exit 0 or 1);
//   - each failed assertion rides stderr as a header
//     `funpack test: <path>:<line>: assertion failed (<name>): <expr>` followed by
//     an excerpt/operand gutter block.
const (
	fakeTestAllPassStdout = "funpack test: 2 passed, 0 failed\n"

	fakeTestSomeFailStdout = "funpack test: 1 passed, 2 failed\n"
	fakeTestSomeFailStderr = "funpack test: /tmp/demo/src/game.fun:8: assertion failed (rows differ fail): Row{value: 1} == Row{value: 2}\n" +
		"  8 |   assert Row{value: 1} == Row{value: 2}\n" +
		"    | left:  Row{value: 1}\n" +
		"    | right: Row{value: 2}\n" +
		"funpack test: /tmp/demo/src/game.fun:12: assertion failed (another fail): Row{value: 7} == Row{value: 9}\n" +
		"  12 |   assert Row{value: 7} == Row{value: 9}\n" +
		"     | left:  Row{value: 7}\n" +
		"     | right: Row{value: 9}\n"
)

// fakeTestFunpack writes an executable shell script standing in for the funpack
// binary, sets $FUNPACK_BIN to it, and returns its path. The script has two modes:
//
//   - `version --json` → emit the contract.VersionInfo JSON funpack.Resolve
//     decodes and exit 0, so the resolver the test tool calls succeeds.
//   - `test` → print stdoutPayload on stdout and stderrPayload on stderr, then exit
//     exitCode, reproducing a real `funpack test` run so the parser is exercised
//     against funpack's true output shape.
//
// POSIX-only — the shebang does not apply on Windows, where callers skip.
func fakeTestFunpack(t *testing.T, exitCode int, stdoutPayload, stderrPayload string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("fake shell-script binary is POSIX-only")
	}
	path := filepath.Join(t.TempDir(), "funpack")

	// version --json must decode into contract.VersionInfo; the schema values sit
	// inside contract.Supported so a future preflight caller is satisfied too.
	versionJSON := `{"version":"v0.0.0-fake","schemas":{"artifact":18,"index":6,"introspect":1}}`

	script := "#!/bin/sh\n" +
		"if [ \"$1\" = \"version\" ] && [ \"$2\" = \"--json\" ]; then\n" +
		"  printf '%s\\n' '" + versionJSON + "'\n" +
		"  exit 0\n" +
		"fi\n" +
		"printf '%s' " + shellSingleQuote(stdoutPayload) + "\n" +
		"printf '%s' " + shellSingleQuote(stderrPayload) + " 1>&2\n" +
		"exit " + itoa(exitCode) + "\n"

	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake funpack: %v", err)
	}
	t.Setenv("FUNPACK_BIN", path)
	return path
}

// shellSingleQuote wraps s in single quotes for safe interpolation into the fake
// script's printf, escaping any embedded single quote with the close-quote /
// backslash-quote / reopen-quote idiom so the captured payload survives verbatim —
// funpack output carries no single quotes, but the escape keeps the helper correct
// regardless.
func shellSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// itoa renders a small non-negative exit code without pulling strconv into the
// test's import set for a single call.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	digits := []byte{}
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}

// projectDir (a throwaway symlink-resolved project dir) is shared with the other
// server-package tool tests — defined once in build_tools_test.go.

// connectTestTool wires a client to a BARE server carrying ONLY the test tool over
// the in-memory loopback transport — registerTestTool exercised in isolation, not
// through server.New. Both sessions close when the test ends.
func connectTestTool(t *testing.T) (*mcp.ClientSession, context.Context) {
	t.Helper()
	ctx := context.Background()

	srv := mcp.NewServer(&mcp.Implementation{Name: "funpack-mcp-test-tool", Version: "v0.0.0"}, nil)
	registerTestTool(srv, zerolog.Nop())

	serverT, clientT := mcp.NewInMemoryTransports()
	serverSession, err := srv.Connect(ctx, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	t.Cleanup(func() { _ = serverSession.Close() })

	client := mcp.NewClient(&mcp.Implementation{Name: "funpack-mcp-test-client", Version: "v0.0.0"}, nil)
	clientSession, err := client.Connect(ctx, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { _ = clientSession.Close() })

	return clientSession, ctx
}

// testToolResult is the decoded TestOutput a test tools/call returns.
type testToolResult struct {
	Ok       bool `json:"ok"`
	Passed   int  `json:"passed"`
	Failed   int  `json:"failed"`
	Total    int  `json:"total"`
	Failures []struct {
		Name    string `json:"name"`
		Message string `json:"message"`
	} `json:"failures"`
	ExitCode int    `json:"exit_code"`
	Raw      string `json:"raw"`
}

// callTest issues a test tools/call and returns the raw result.
func callTest(t *testing.T, session *mcp.ClientSession, ctx context.Context, args map[string]any) *mcp.CallToolResult {
	t.Helper()
	res, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "test", Arguments: args})
	if err != nil {
		t.Fatalf("call test: %v", err)
	}
	return res
}

// decodeTest pulls the TestOutput out of a tool result's TextContent.
func decodeTest(t *testing.T, res *mcp.CallToolResult) testToolResult {
	t.Helper()
	var out testToolResult
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode TestOutput: %v; raw: %s", err, callText(res))
	}
	return out
}

// TestTestToolAllPassParsesCounts proves an all-pass run (exit 0) parses the
// summary counts, sets Ok, reports no failures, and passes the raw output through.
func TestTestToolAllPassParsesCounts(t *testing.T) {
	fakeTestFunpack(t, 0, fakeTestAllPassStdout, "")
	dir := projectDir(t)
	session, ctx := connectTestTool(t)

	res := callTest(t, session, ctx, map[string]any{"dir": dir})
	if res.IsError {
		t.Fatalf("test reported a tool error on an all-pass run: %s", callText(res))
	}
	out := decodeTest(t, res)
	if !out.Ok {
		t.Fatalf("Ok=false on an exit-0 run; want true")
	}
	if out.Passed != 2 || out.Failed != 0 || out.Total != 2 {
		t.Fatalf("counts = passed %d failed %d total %d, want 2/0/2", out.Passed, out.Failed, out.Total)
	}
	if len(out.Failures) != 0 {
		t.Fatalf("Failures = %+v, want empty on an all-pass run", out.Failures)
	}
	if !strings.Contains(out.Raw, "2 passed, 0 failed") {
		t.Fatalf("Raw missing the summary line; got %q", out.Raw)
	}
}

// TestTestToolSomeFailParsesFailures is the central convention: a failing suite
// (funpack exit 1) is a NORMAL result with Ok false — not an IsError envelope. The
// parser extracts the counts and lifts each per-failure block into a name+message
// pair, and Ok reflects the non-zero exit.
func TestTestToolSomeFailParsesFailures(t *testing.T) {
	fakeTestFunpack(t, 1, fakeTestSomeFailStdout, fakeTestSomeFailStderr)
	dir := projectDir(t)
	session, ctx := connectTestTool(t)

	res := callTest(t, session, ctx, map[string]any{"dir": dir})
	if res.IsError {
		t.Fatalf("a failing test suite was reported as a tool error: %s", callText(res))
	}
	out := decodeTest(t, res)
	if out.Ok {
		t.Fatalf("Ok=true on an exit-1 run; want false")
	}
	if out.ExitCode != 1 {
		t.Fatalf("ExitCode = %d, want 1", out.ExitCode)
	}
	if out.Passed != 1 || out.Failed != 2 || out.Total != 3 {
		t.Fatalf("counts = passed %d failed %d total %d, want 1/2/3", out.Passed, out.Failed, out.Total)
	}
	if len(out.Failures) != 2 {
		t.Fatalf("Failures count = %d, want 2; got %+v", len(out.Failures), out.Failures)
	}
	if out.Failures[0].Name != "rows differ fail" || out.Failures[1].Name != "another fail" {
		t.Fatalf("failure names = [%q %q], want [rows differ fail, another fail]", out.Failures[0].Name, out.Failures[1].Name)
	}
	for _, f := range out.Failures {
		if !strings.Contains(f.Message, "assertion failed") || !strings.Contains(f.Message, ".fun:") {
			t.Fatalf("failure message lost its location/expression detail: %q", f.Message)
		}
	}
	// The number of parsed failures must agree with the summary's failed count, the
	// invariant the agent relies on when branching on Failed vs Failures.
	if len(out.Failures) != out.Failed {
		t.Fatalf("parsed %d failure blocks but summary reported %d failed", len(out.Failures), out.Failed)
	}
}

// TestTestToolCompileErrorPassesRawThrough proves the documented parse limit: a
// compile error / malformed tree (funpack exit 2) emits no summary line, so the
// counts stay zero and Ok is false, but the diagnostic survives verbatim in Raw —
// the parser is additive, never lossy.
func TestTestToolCompileErrorPassesRawThrough(t *testing.T) {
	const diag = "funpack test: /tmp/demo/src/game.fun:3:21: Unexpected_Token: unexpected token here — the grammar expects a different construct at this position\n" +
		"  3 |   assert Row{value: == }\n" +
		"    |                     ^\n"
	fakeTestFunpack(t, 2, "", diag)
	dir := projectDir(t)
	session, ctx := connectTestTool(t)

	res := callTest(t, session, ctx, map[string]any{"dir": dir})
	if res.IsError {
		t.Fatalf("a compile error was reported as a tool error rather than a normal result: %s", callText(res))
	}
	out := decodeTest(t, res)
	if out.Ok {
		t.Fatalf("Ok=true on an exit-2 compile error; want false")
	}
	if out.ExitCode != 2 {
		t.Fatalf("ExitCode = %d, want 2", out.ExitCode)
	}
	if out.Passed != 0 || out.Failed != 0 || out.Total != 0 {
		t.Fatalf("counts = passed %d failed %d total %d, want 0/0/0 (no summary line on a compile error)", out.Passed, out.Failed, out.Total)
	}
	if len(out.Failures) != 0 {
		t.Fatalf("Failures = %+v, want empty (the diagnostic is not an assertion failure)", out.Failures)
	}
	if !strings.Contains(out.Raw, "Unexpected_Token") {
		t.Fatalf("Raw lost the compile diagnostic; got %q", out.Raw)
	}
}

// TestTestToolEmptyDirIsToolError proves a present-but-empty Dir is a structured
// invalid_input tool error the agent can read and self-correct from — never a
// silent run in the server's own cwd. (An entirely ABSENT dir is caught one layer
// earlier by the SDK's required-property gate; this is the in-tool backstop.)
func TestTestToolEmptyDirIsToolError(t *testing.T) {
	fakeTestFunpack(t, 0, fakeTestAllPassStdout, "")
	session, ctx := connectTestTool(t)

	res := callTest(t, session, ctx, map[string]any{"dir": ""})
	if !res.IsError {
		t.Fatal("test did not flag IsError for an empty dir")
	}
	got := callText(res)
	for _, want := range []string{`"category":"invalid_input"`, "dir is required"} {
		if !strings.Contains(got, want) {
			t.Fatalf("empty-dir error envelope missing %q; got: %s", want, got)
		}
	}
}

// TestTestToolResolveFailureIsToolError proves a resolve failure surfaces a
// structured resolver tool error rather than a protocol fault.
func TestTestToolResolveFailureIsToolError(t *testing.T) {
	// Force a host-independent resolve miss via a separator-bearing absent path —
	// stat'd literally, never PATH/common-paths probed. See the build-tool twin for
	// why an empty PATH alone is insufficient (commonFunpackPaths still resolves a
	// brew funpack).
	t.Setenv("FUNPACK_BIN", filepath.Join(t.TempDir(), "absent", "funpack"))
	dir := projectDir(t)
	session, ctx := connectTestTool(t)

	res := callTest(t, session, ctx, map[string]any{"dir": dir})
	if !res.IsError {
		t.Fatalf("test did not flag IsError when funpack could not be resolved: %s", callText(res))
	}
	if got := callText(res); !strings.Contains(got, `"category":"resolver"`) {
		t.Fatalf("resolve-failure envelope missing resolver category; got: %s", got)
	}
}

// TestListAdvertisesTestTool confirms the test tool appears in tools/list so an
// agent can discover it before calling.
func TestListAdvertisesTestTool(t *testing.T) {
	session, ctx := connectTestTool(t)

	res, err := session.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	for _, tool := range res.Tools {
		if tool.Name == "test" {
			return
		}
	}
	t.Fatal("test tool not advertised in tools/list")
}
