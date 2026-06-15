package server

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// fakeFunpack writes an executable shell script standing in for the funpack
// binary, sets $FUNPACK_BIN to it for the test, and returns its path. The script
// has two modes:
//
//   - `version --json` → emit the contract.VersionInfo JSON Resolve decodes and
//     exit 0, so funpack.Resolve's version preflight succeeds.
//   - any other argv → echo the full argv and the working directory as JSON on
//     stdout, a fixed marker on stderr, and exit with exitCode, so a tool test can
//     assert which verb/flags funpack received, that the project Dir was honored,
//     and that a chosen exit code flows through to Ok.
//
// POSIX-only — the shebang does not apply on Windows, where callers skip.
func fakeFunpack(t *testing.T, exitCode int) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("fake shell-script binary is POSIX-only")
	}
	path := filepath.Join(t.TempDir(), "funpack")

	// version --json must decode into contract.VersionInfo; the schema values sit
	// inside contract.Supported so a future ResolveAndPreflight caller is happy too.
	versionJSON := `{"version":"v0.0.0-fake","schemas":{"artifact":18,"index":6,"introspect":1}}`

	script := "#!/bin/sh\n" +
		"if [ \"$1\" = \"version\" ] && [ \"$2\" = \"--json\" ]; then\n" +
		"  printf '%s\\n' '" + versionJSON + "'\n" +
		"  exit 0\n" +
		"fi\n" +
		// Emit argv as a JSON array and the cwd as a JSON string so the test can
		// parse exactly what funpack was invoked with and where.
		"printf 'ARGV='\n" +
		"sep=''\n" +
		"printf '['\n" +
		"for a in \"$@\"; do printf '%s\"%s\"' \"$sep\" \"$a\"; sep=','; done\n" +
		"printf ']\\n'\n" +
		"printf 'CWD=%s\\n' \"$(pwd)\"\n" +
		"printf 'diagnostic-line\\n' 1>&2\n" +
		"exit " + strconv.Itoa(exitCode) + "\n"

	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake funpack: %v", err)
	}
	t.Setenv("FUNPACK_BIN", path)
	return path
}

// projectDir makes a throwaway project directory whose resolved (symlink-free)
// absolute path the test asserts the verb ran in. macOS TempDir lives under a
// /var → /private/var symlink, and the fake script reports `pwd` (the physical
// path), so the expectation must be the EvalSymlinks form, not the raw TempDir.
func projectDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatalf("resolve project dir: %v", err)
	}
	return resolved
}

// connectBuildTools wires a client to a bare server carrying ONLY the build-family
// tools over the in-memory loopback transport — registerBuildTools exercised in
// isolation, not through server.New. Both sessions close when the test ends.
func connectBuildTools(t *testing.T) (*mcp.ClientSession, context.Context) {
	t.Helper()
	ctx := context.Background()

	srv := mcp.NewServer(&mcp.Implementation{Name: "funpack-mcp-build-test", Version: "v0.0.0"}, nil)
	registerBuildTools(srv, zerolog.Nop())

	serverT, clientT := mcp.NewInMemoryTransports()
	serverSession, err := srv.Connect(ctx, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	t.Cleanup(func() { _ = serverSession.Close() })

	client := mcp.NewClient(&mcp.Implementation{Name: "funpack-mcp-build-client", Version: "v0.0.0"}, nil)
	clientSession, err := client.Connect(ctx, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { _ = clientSession.Close() })

	return clientSession, ctx
}

// commandResult is the decoded CommandOutput a build-family tool returns.
type commandResult struct {
	ExitCode int    `json:"exit_code"`
	Stdout   string `json:"stdout"`
	Stderr   string `json:"stderr"`
	Ok       bool   `json:"ok"`
}

// callVerb issues a tools/call for a build-family tool and returns the raw result.
func callVerb(t *testing.T, session *mcp.ClientSession, ctx context.Context, name string, args map[string]any) *mcp.CallToolResult {
	t.Helper()
	res, err := session.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("call %s: %v", name, err)
	}
	return res
}

// decodeCommand pulls the CommandOutput out of a tool result's TextContent.
func decodeCommand(t *testing.T, res *mcp.CallToolResult) commandResult {
	t.Helper()
	var out commandResult
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode CommandOutput: %v; raw: %s", err, callText(res))
	}
	return out
}

// parseArgv extracts the JSON argv array the fake funpack echoed on stdout.
func parseArgv(t *testing.T, stdout string) []string {
	t.Helper()
	const prefix = "ARGV="
	var line string
	for _, l := range strings.Split(stdout, "\n") {
		if strings.HasPrefix(l, prefix) {
			line = strings.TrimPrefix(l, prefix)
			break
		}
	}
	if line == "" {
		t.Fatalf("no ARGV= line in fake funpack stdout: %q", stdout)
	}
	var argv []string
	if err := json.Unmarshal([]byte(line), &argv); err != nil {
		t.Fatalf("parse argv %q: %v", line, err)
	}
	return argv
}

// parseCWD extracts the working directory the fake funpack echoed on stdout.
func parseCWD(t *testing.T, stdout string) string {
	t.Helper()
	const prefix = "CWD="
	for _, l := range strings.Split(stdout, "\n") {
		if strings.HasPrefix(l, prefix) {
			return strings.TrimPrefix(l, prefix)
		}
	}
	t.Fatalf("no CWD= line in fake funpack stdout: %q", stdout)
	return ""
}

// TestBuildPassesBuildAndHonorsDir proves the build tool runs `funpack build` in
// the requested project directory and flows the streams and zero exit through to
// Ok.
func TestBuildPassesBuildAndHonorsDir(t *testing.T) {
	fakeFunpack(t, 0)
	dir := projectDir(t)
	session, ctx := connectBuildTools(t)

	res := callVerb(t, session, ctx, "build", map[string]any{"dir": dir})
	if res.IsError {
		t.Fatalf("build reported a tool error: %s", callText(res))
	}
	out := decodeCommand(t, res)
	if !out.Ok || out.ExitCode != 0 {
		t.Fatalf("build Ok=%v ExitCode=%d, want Ok=true ExitCode=0", out.Ok, out.ExitCode)
	}
	if got := parseArgv(t, out.Stdout); len(got) != 1 || got[0] != "build" {
		t.Fatalf("argv = %v, want [build]", got)
	}
	if got := parseCWD(t, out.Stdout); got != dir {
		t.Fatalf("cwd = %q, want %q", got, dir)
	}
	if !strings.Contains(out.Stderr, "diagnostic-line") {
		t.Fatalf("stderr passthrough missing; got %q", out.Stderr)
	}
}

// TestBuildReleasePassesReleaseFlag proves Release threads --release into the
// build argv.
func TestBuildReleasePassesReleaseFlag(t *testing.T) {
	fakeFunpack(t, 0)
	dir := projectDir(t)
	session, ctx := connectBuildTools(t)

	res := callVerb(t, session, ctx, "build", map[string]any{"dir": dir, "release": true})
	if res.IsError {
		t.Fatalf("build --release reported a tool error: %s", callText(res))
	}
	got := parseArgv(t, decodeCommand(t, res).Stdout)
	if len(got) != 2 || got[0] != "build" || got[1] != "--release" {
		t.Fatalf("argv = %v, want [build --release]", got)
	}
}

// TestExportIsBuildRelease proves export is a thin alias for `build --release` —
// the shippable build — regardless of any release flag the caller sends.
func TestExportIsBuildRelease(t *testing.T) {
	fakeFunpack(t, 0)
	dir := projectDir(t)
	session, ctx := connectBuildTools(t)

	res := callVerb(t, session, ctx, "export", map[string]any{"dir": dir})
	if res.IsError {
		t.Fatalf("export reported a tool error: %s", callText(res))
	}
	got := parseArgv(t, decodeCommand(t, res).Stdout)
	if len(got) != 2 || got[0] != "build" || got[1] != "--release" {
		t.Fatalf("export argv = %v, want [build --release]", got)
	}
}

// TestCheckPassesCheck proves the check tool runs `funpack check`, and that
// Release threads --release.
func TestCheckPassesCheck(t *testing.T) {
	fakeFunpack(t, 0)
	dir := projectDir(t)
	session, ctx := connectBuildTools(t)

	plain := parseArgv(t, decodeCommand(t, callVerb(t, session, ctx, "check", map[string]any{"dir": dir})).Stdout)
	if len(plain) != 1 || plain[0] != "check" {
		t.Fatalf("check argv = %v, want [check]", plain)
	}

	rel := parseArgv(t, decodeCommand(t, callVerb(t, session, ctx, "check", map[string]any{"dir": dir, "release": true})).Stdout)
	if len(rel) != 2 || rel[0] != "check" || rel[1] != "--release" {
		t.Fatalf("check --release argv = %v, want [check --release]", rel)
	}
}

// TestFmtCheckPassesCheckFlag proves the fmt tool runs `funpack fmt`, and that
// Check threads --check (verdict-only).
func TestFmtCheckPassesCheckFlag(t *testing.T) {
	fakeFunpack(t, 0)
	dir := projectDir(t)
	session, ctx := connectBuildTools(t)

	plain := parseArgv(t, decodeCommand(t, callVerb(t, session, ctx, "fmt", map[string]any{"dir": dir})).Stdout)
	if len(plain) != 1 || plain[0] != "fmt" {
		t.Fatalf("fmt argv = %v, want [fmt]", plain)
	}

	chk := parseArgv(t, decodeCommand(t, callVerb(t, session, ctx, "fmt", map[string]any{"dir": dir, "check": true})).Stdout)
	if len(chk) != 2 || chk[0] != "fmt" || chk[1] != "--check" {
		t.Fatalf("fmt --check argv = %v, want [fmt --check]", chk)
	}
}

// TestNonZeroExitIsNormalResultNotError is the central convention: a non-zero
// funpack exit (a failing check, formatting drift) is a NORMAL tool result with
// Ok false — not an IsError envelope. The agent reads the code and the
// diagnostics and branches itself.
func TestNonZeroExitIsNormalResultNotError(t *testing.T) {
	fakeFunpack(t, 2)
	dir := projectDir(t)
	session, ctx := connectBuildTools(t)

	res := callVerb(t, session, ctx, "check", map[string]any{"dir": dir})
	if res.IsError {
		t.Fatalf("a non-zero funpack exit was reported as a tool error: %s", callText(res))
	}
	out := decodeCommand(t, res)
	if out.Ok {
		t.Fatalf("Ok=true for a non-zero exit; want false")
	}
	if out.ExitCode != 2 {
		t.Fatalf("ExitCode = %d, want 2", out.ExitCode)
	}
	if !strings.Contains(out.Stderr, "diagnostic-line") {
		t.Fatalf("stderr diagnostics missing on a failing run; got %q", out.Stderr)
	}
}

// TestEmptyDirIsToolError proves an explicitly empty Dir is a structured
// invalid_input tool error the agent can read and self-correct from — never a
// silent run in the server's own cwd. (An entirely ABSENT dir is caught one layer
// earlier by the SDK's required-property jsonschema gate; the handler guard here
// is the in-tool backstop for a present-but-empty value.)
func TestEmptyDirIsToolError(t *testing.T) {
	fakeFunpack(t, 0)
	session, ctx := connectBuildTools(t)

	res := callVerb(t, session, ctx, "build", map[string]any{"dir": ""})
	if !res.IsError {
		t.Fatal("build did not flag IsError for an empty dir")
	}
	got := callText(res)
	for _, want := range []string{`"category":"invalid_input"`, "dir is required"} {
		if !strings.Contains(got, want) {
			t.Fatalf("empty-dir error envelope missing %q; got: %s", want, got)
		}
	}
}

// TestResolveFailureIsToolError proves a resolve failure — no funpack on PATH and
// no $FUNPACK_BIN — surfaces a structured resolver tool error rather than a
// protocol fault.
func TestResolveFailureIsToolError(t *testing.T) {
	// Empty FUNPACK_BIN and an empty PATH guarantee Resolve cannot locate funpack.
	t.Setenv("FUNPACK_BIN", "")
	t.Setenv("PATH", "")
	dir := projectDir(t)
	session, ctx := connectBuildTools(t)

	res := callVerb(t, session, ctx, "build", map[string]any{"dir": dir})
	if !res.IsError {
		t.Fatalf("build did not flag IsError when funpack could not be resolved: %s", callText(res))
	}
	if got := callText(res); !strings.Contains(got, `"category":"resolver"`) {
		t.Fatalf("resolve-failure envelope missing resolver category; got: %s", got)
	}
}

// TestListAdvertisesBuildTools confirms all four verbs appear in tools/list so an
// agent can discover them before calling.
func TestListAdvertisesBuildTools(t *testing.T) {
	session, ctx := connectBuildTools(t)

	res, err := session.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	advertised := make(map[string]bool, len(res.Tools))
	for _, tool := range res.Tools {
		advertised[tool.Name] = true
	}
	for _, want := range []string{"build", "export", "check", "fmt"} {
		if !advertised[want] {
			t.Fatalf("tool %q not advertised in tools/list", want)
		}
	}
}
