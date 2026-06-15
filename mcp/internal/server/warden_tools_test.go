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

// wardenFakeScript is a fake `funpack` binary the warden tool tests drive instead
// of a real engine. It answers two argv shapes:
//
//   - `version --json` → the minimal VersionInfo JSON funpack.Resolve decodes, so
//     binary resolution succeeds without a real funpack build.
//   - `warden <sub> [args...]` → echoes a parseable transcript of the subcommand,
//     its args, and the cwd to stdout, then either exits 0 with a canned NDJSON
//     row (the index-present path) or exits 2 with a refusal on stderr (the
//     index-missing path), selected by $WARDEN_FAKE_EXIT.
//
// The transcript lets a test assert the exact subcommand+args the tool passed and
// that Dir was honored as the child's working directory.
const wardenFakeScript = `#!/bin/sh
if [ "$1" = "version" ] && [ "$2" = "--json" ]; then
  printf '{"version":"v-test","schemas":{}}\n'
  exit 0
fi
if [ "$1" = "warden" ]; then
  printf 'ARGV:%s\n' "$*"
  printf 'CWD:%s\n' "$(pwd)"
  if [ "${WARDEN_FAKE_EXIT:-0}" = "2" ]; then
    printf 'funpack warden: .funpack/index.ndjson is missing\n' 1>&2
    exit 2
  fi
  printf '{"kind":"Fn","name":"sample.decl"}\n'
  exit 0
fi
printf 'unexpected argv: %s\n' "$*" 1>&2
exit 64
`

// withFakeWarden writes the fake funpack script, points $FUNPACK_BIN at it for the
// duration of the test, and sets $WARDEN_FAKE_EXIT so the warden branch exits with
// the given code (0 = index present, 2 = index refusal). POSIX-only; skips on
// Windows where the shebang does not apply.
func withFakeWarden(t *testing.T, wardenExit int) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("fake shell-script funpack binary is POSIX-only")
	}
	path := filepath.Join(t.TempDir(), "funpack")
	if err := os.WriteFile(path, []byte(wardenFakeScript), 0o755); err != nil {
		t.Fatalf("write fake funpack: %v", err)
	}
	t.Setenv("FUNPACK_BIN", path)
	if wardenExit == 2 {
		t.Setenv("WARDEN_FAKE_EXIT", "2")
	} else {
		t.Setenv("WARDEN_FAKE_EXIT", "0")
	}
}

// connectWardenServer wires a BARE server — one with only the warden tools
// registered, not the full New() surface — to a client over the in-memory
// transport, so the warden tools are exercised in isolation. Both sessions close
// when the test ends.
func connectWardenServer(t *testing.T) (*mcp.ClientSession, context.Context) {
	t.Helper()
	ctx := context.Background()

	srv := mcp.NewServer(&mcp.Implementation{Name: "funpack-mcp-warden-test", Version: "v0.0.0"}, nil)
	registerWardenTools(srv, zerolog.Nop())

	serverT, clientT := mcp.NewInMemoryTransports()
	serverSession, err := srv.Connect(ctx, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	t.Cleanup(func() { _ = serverSession.Close() })

	client := mcp.NewClient(&mcp.Implementation{Name: "funpack-mcp-warden-client", Version: "v0.0.0"}, nil)
	clientSession, err := client.Connect(ctx, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { _ = clientSession.Close() })

	return clientSession, ctx
}

// decodeWarden unmarshals the WardenOutput structured result from a tool result's
// TextContent. The handler returns a typed Output the SDK marshals into the
// result's text payload as a structured JSON object.
func decodeWarden(t *testing.T, res *mcp.CallToolResult) WardenOutput {
	t.Helper()
	var out WardenOutput
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode warden output: %v; raw: %s", err, callText(res))
	}
	return out
}

// callWarden issues a warden tools/call over the wire and returns the raw result.
func callWarden(t *testing.T, session *mcp.ClientSession, ctx context.Context, name string, args map[string]any) *mcp.CallToolResult {
	t.Helper()
	res, err := session.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("call %s: %v", name, err)
	}
	return res
}

// TestWardenBareSubcommandsPassArgsAndHonorDir proves each no-argument warden tool
// passes exactly `warden <sub>` (no stray args) and runs in the requested Dir,
// with the canned NDJSON flowing through Stdout and Ok=true on a clean exit. One
// test exercises the whole no-arg cohort so a new bare subcommand is folded into
// this junction rather than getting a bespoke test.
func TestWardenBareSubcommandsPassArgsAndHonorDir(t *testing.T) {
	withFakeWarden(t, 0)
	dir := t.TempDir()
	session, ctx := connectWardenServer(t)

	cases := []struct {
		tool    string
		wantArg string // the full `warden ...` argv the transcript must echo
	}{
		{"warden_holes", "warden holes"},
		{"warden_probes", "warden probes"},
		{"warden_debt", "warden debt"},
		{"warden_tags", "warden tags"},
		{"warden_pipeline", "warden pipeline"},
	}
	for _, c := range cases {
		t.Run(c.tool, func(t *testing.T) {
			res := callWarden(t, session, ctx, c.tool, map[string]any{"dir": dir})
			if res.IsError {
				t.Fatalf("%s reported a tool error: %s", c.tool, callText(res))
			}
			out := decodeWarden(t, res)
			if !out.Ok {
				t.Fatalf("%s: Ok = false on a clean exit; out: %+v", c.tool, out)
			}
			if out.ExitCode != 0 {
				t.Fatalf("%s: ExitCode = %d, want 0", c.tool, out.ExitCode)
			}
			if !strings.Contains(out.Stdout, "ARGV:"+c.wantArg+"\n") {
				t.Fatalf("%s: stdout did not echo %q; got: %q", c.tool, c.wantArg, out.Stdout)
			}
			// The canned NDJSON row must pass through verbatim in Stdout.
			if !strings.Contains(out.Stdout, `{"kind":"Fn","name":"sample.decl"}`) {
				t.Fatalf("%s: NDJSON row did not flow through stdout; got: %q", c.tool, out.Stdout)
			}
			// Dir was honored as the child's working directory.
			if !wardenCWDMatches(out.Stdout, dir) {
				t.Fatalf("%s: cwd not honored; want %q in stdout: %q", c.tool, dir, out.Stdout)
			}
		})
	}
}

// TestWardenFindPassesQueryPositional proves warden_find passes the Query as the
// `warden find <query>` positional argument and flows the canned NDJSON through.
func TestWardenFindPassesQueryPositional(t *testing.T) {
	withFakeWarden(t, 0)
	dir := t.TempDir()
	session, ctx := connectWardenServer(t)

	res := callWarden(t, session, ctx, "warden_find", map[string]any{"dir": dir, "query": "world.resolve"})
	if res.IsError {
		t.Fatalf("warden_find reported a tool error: %s", callText(res))
	}
	out := decodeWarden(t, res)
	if !out.Ok || out.ExitCode != 0 {
		t.Fatalf("warden_find: Ok=%v ExitCode=%d, want true/0", out.Ok, out.ExitCode)
	}
	if !strings.Contains(out.Stdout, "ARGV:warden find world.resolve\n") {
		t.Fatalf("warden_find did not pass the query positional; got: %q", out.Stdout)
	}
	if !strings.Contains(out.Stdout, `{"kind":"Fn","name":"sample.decl"}`) {
		t.Fatalf("warden_find NDJSON row did not flow through; got: %q", out.Stdout)
	}
}

// TestWardenFindEmptyQueryIsStructuredError proves an empty find query surfaces
// the structured invalid_input IsError envelope rather than shelling out with no
// filter, matching the warden find contract that at least one filter is required.
func TestWardenFindEmptyQueryIsStructuredError(t *testing.T) {
	withFakeWarden(t, 0)
	session, ctx := connectWardenServer(t)

	res := callWarden(t, session, ctx, "warden_find", map[string]any{"dir": t.TempDir(), "query": ""})
	if !res.IsError {
		t.Fatal("warden_find did not flag IsError for an empty query")
	}
	got := callText(res)
	for _, want := range []string{`"category":"invalid_input"`, "query must not be empty"} {
		if !strings.Contains(got, want) {
			t.Fatalf("warden_find error envelope missing %q; got: %s", want, got)
		}
	}
}

// TestWardenGraphOmitsNodeWhenUnset proves warden_graph passes a bare `warden
// graph` (no positional) when Node is unset — the full-graph projection path.
func TestWardenGraphOmitsNodeWhenUnset(t *testing.T) {
	withFakeWarden(t, 0)
	dir := t.TempDir()
	session, ctx := connectWardenServer(t)

	res := callWarden(t, session, ctx, "warden_graph", map[string]any{"dir": dir})
	if res.IsError {
		t.Fatalf("warden_graph reported a tool error: %s", callText(res))
	}
	out := decodeWarden(t, res)
	if !strings.Contains(out.Stdout, "ARGV:warden graph\n") {
		t.Fatalf("warden_graph should pass a bare `warden graph` when Node is unset; got: %q", out.Stdout)
	}
}

// TestWardenGraphPassesNodeFilter proves a set Node becomes the `warden graph
// <node>` positional filter.
func TestWardenGraphPassesNodeFilter(t *testing.T) {
	withFakeWarden(t, 0)
	dir := t.TempDir()
	session, ctx := connectWardenServer(t)

	res := callWarden(t, session, ctx, "warden_graph", map[string]any{"dir": dir, "node": "physics.step"})
	if res.IsError {
		t.Fatalf("warden_graph reported a tool error: %s", callText(res))
	}
	out := decodeWarden(t, res)
	if !strings.Contains(out.Stdout, "ARGV:warden graph physics.step\n") {
		t.Fatalf("warden_graph did not pass the node filter positional; got: %q", out.Stdout)
	}
}

// TestWardenIndexRefusalIsNormalResult is the exit-2 contract: a warden subcommand
// refusing because the index is missing/malformed (exit 2) is a NORMAL result —
// Ok=false with the refusal in Stderr and ExitCode=2 — NOT an IsError tool fault.
// The model reads the result and self-corrects; it never sees a protocol error.
func TestWardenIndexRefusalIsNormalResult(t *testing.T) {
	withFakeWarden(t, 2)
	dir := t.TempDir()
	session, ctx := connectWardenServer(t)

	res := callWarden(t, session, ctx, "warden_tags", map[string]any{"dir": dir})
	if res.IsError {
		t.Fatalf("an index refusal (exit 2) must NOT be an IsError tool fault; got: %s", callText(res))
	}
	out := decodeWarden(t, res)
	if out.Ok {
		t.Fatalf("warden_tags: Ok = true on an exit-2 refusal; want false; out: %+v", out)
	}
	if out.ExitCode != 2 {
		t.Fatalf("warden_tags: ExitCode = %d, want 2 on a refusal", out.ExitCode)
	}
	if !strings.Contains(out.Stderr, ".funpack/index.ndjson is missing") {
		t.Fatalf("warden_tags: refusal text missing from Stderr; got: %q", out.Stderr)
	}
}

// TestWardenResolveFailureIsToolError proves a genuine binary-resolution failure
// (no $FUNPACK_BIN and no funpack on PATH) surfaces as a structured resolver
// IsError envelope — the only condition the warden tools treat as a tool fault,
// distinct from a captured non-zero exit.
func TestWardenResolveFailureIsToolError(t *testing.T) {
	// Force resolution to miss: empty FUNPACK_BIN and an empty PATH so LookPath
	// cannot find a funpack anywhere.
	t.Setenv("FUNPACK_BIN", "")
	t.Setenv("PATH", "")
	session, ctx := connectWardenServer(t)

	res := callWarden(t, session, ctx, "warden_holes", map[string]any{"dir": t.TempDir()})
	if !res.IsError {
		t.Fatal("warden_holes did not flag IsError when no funpack binary could be resolved")
	}
	got := callText(res)
	if !strings.Contains(got, `"category":"resolver"`) {
		t.Fatalf("warden_holes resolve failure envelope missing resolver category; got: %s", got)
	}
}

// wardenCWDMatches reports whether the fake transcript's CWD line resolves to the
// same path as want, comparing through EvalSymlinks so macOS's /var → /private/var
// symlink (and a /tmp temp dir) does not spuriously fail the match.
func wardenCWDMatches(stdout, want string) bool {
	const marker = "CWD:"
	var got string
	for _, line := range strings.Split(stdout, "\n") {
		if strings.HasPrefix(line, marker) {
			got = strings.TrimPrefix(line, marker)
			break
		}
	}
	if got == "" {
		return false
	}
	gotResolved, err := filepath.EvalSymlinks(got)
	if err != nil {
		gotResolved = got
	}
	wantResolved, err := filepath.EvalSymlinks(want)
	if err != nil {
		wantResolved = want
	}
	return gotResolved == wantResolved
}
