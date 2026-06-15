package server

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// fakeCaller is the FAKE §28 caller the self-heal tests drive against: every Call
// records the command + args it was issued and returns a canned response (or a
// canned transport error), so the tools' arg-marshal → Call → Response-map logic
// runs with no registry and no live runtime. resp is returned by value-pointer so
// each Call hands back a fresh response.
type fakeCaller struct {
	resp     *contract.Response
	callErr  error
	gotCmd   string
	gotArgs  json.RawMessage
	callsLog int
}

func (f *fakeCaller) Call(_ context.Context, cmd string, args json.RawMessage) (*contract.Response, error) {
	f.callsLog++
	f.gotCmd = cmd
	f.gotArgs = args
	if f.callErr != nil {
		return nil, f.callErr
	}
	return f.resp, nil
}

// connectSelfHealTools wires a BARE server (no New, so server.go is untouched)
// carrying ONLY the self-heal tools, with the id→caller resolve seam injected over
// the supplied resolver. It returns the connected client and the context.
func connectSelfHealTools(t *testing.T, resolve callerResolver) (*mcp.ClientSession, context.Context) {
	t.Helper()
	ctx := context.Background()

	srv := mcp.NewServer(&mcp.Implementation{Name: "funpack-mcp-test", Version: "v0.0.0"}, nil)
	registerSelfHealToolsWith(srv, zerolog.Nop(), resolve)

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

// resolveTo returns a callerResolver that hands every id the supplied caller — the
// "session exists" path. Pairing it with a fakeCaller drives the §28 command path.
func resolveTo(c caller) callerResolver {
	return func(string) (caller, bool) { return c, true }
}

// okResponse builds a well-formed §28 success Response carrying result as its
// Result payload — the canned shape the runtime returns on a successful command.
func okResponse(t *testing.T, cmd string, result any) *contract.Response {
	t.Helper()
	raw, err := json.Marshal(result)
	if err != nil {
		t.Fatalf("marshal canned result: %v", err)
	}
	msg := json.RawMessage(raw)
	return &contract.Response{V: contract.ProtocolVersion, Ok: true, Cmd: cmd, Result: &msg}
}

// TestCaptureTestReturnsEmittedTestBlock proves capture_test marshals its args to
// the runtime contract shape, issues the capture_test command, and surfaces the
// emitted funpack test block (the debugger-output-IS-a-regression-test payoff)
// verbatim from the canned result — no live runtime.
func TestCaptureTestReturnsEmittedTestBlock(t *testing.T) {
	const emitted = "@doc(\"Captured by capture_test: tick_clock on Clock#3 at tick 7 of a recorded session.\")\n" +
		"test \"captured tick_clock tick 7 instance 3\" {\n" +
		"  assert tick_clock.step(Clock{count: 41}, Input.empty()) == Clock{count: 42}\n" +
		"}\n"
	fc := &fakeCaller{resp: okResponse(t, string(contract.CmdCaptureTest), map[string]any{
		"tick":     7,
		"behavior": "tick_clock",
		"instance": 3,
		"test":     emitted,
	})}
	cs, ctx := connectSelfHealTools(t, resolveTo(fc))

	res := callTool(t, cs, ctx, "capture_test", map[string]any{
		"session_id": "sess-1",
		"behavior":   "tick_clock",
		"tick":       7,
	})
	if res.IsError {
		t.Fatalf("capture_test reported a tool error: %s", callText(res))
	}

	// The runtime saw the capture_test command with the contract-shaped args.
	if fc.gotCmd != string(contract.CmdCaptureTest) {
		t.Fatalf("capture_test issued command %q, want %q", fc.gotCmd, contract.CmdCaptureTest)
	}
	var sentArgs captureArgs
	if err := json.Unmarshal(fc.gotArgs, &sentArgs); err != nil {
		t.Fatalf("decode args the tool sent: %v; raw: %s", err, fc.gotArgs)
	}
	if sentArgs.Tick != 7 || sentArgs.Behavior != "tick_clock" {
		t.Fatalf("capture_test sent wrong args: %+v", sentArgs)
	}
	if sentArgs.Instance != nil {
		t.Fatalf("capture_test sent an instance %v when none was requested (must omit so the runtime defaults)", *sentArgs.Instance)
	}

	var out CaptureTestOutput
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode capture_test output: %v; raw: %s", err, callText(res))
	}
	if out.Test != emitted {
		t.Fatalf("capture_test did not surface the emitted test block verbatim:\n got: %q\nwant: %q", out.Test, emitted)
	}
	if out.Tick != 7 || out.Behavior != "tick_clock" || out.Instance != 3 {
		t.Fatalf("capture_test provenance wrong: %+v", out)
	}
}

// TestCaptureTestForwardsInstance proves an explicit instance is threaded into the
// runtime args (so the runtime targets one Thing rather than the fold-order
// default).
func TestCaptureTestForwardsInstance(t *testing.T) {
	fc := &fakeCaller{resp: okResponse(t, string(contract.CmdCaptureTest), map[string]any{
		"tick": 2, "behavior": "mover", "instance": 9, "test": "test \"x\" {\n}\n",
	})}
	cs, ctx := connectSelfHealTools(t, resolveTo(fc))

	res := callTool(t, cs, ctx, "capture_test", map[string]any{
		"session_id": "sess-1", "behavior": "mover", "tick": 2, "instance": 9,
	})
	if res.IsError {
		t.Fatalf("capture_test reported a tool error: %s", callText(res))
	}
	var sentArgs captureArgs
	if err := json.Unmarshal(fc.gotArgs, &sentArgs); err != nil {
		t.Fatalf("decode args the tool sent: %v", err)
	}
	if sentArgs.Instance == nil || *sentArgs.Instance != 9 {
		t.Fatalf("capture_test did not forward instance=9: %+v", sentArgs)
	}
}

// TestAuditWarrantedOnCleanRefold proves audit issues the audit command with NO
// args (a whole-run property) and surfaces warranted=true from a canned clean
// re-fold, with no divergence block.
func TestAuditWarrantedOnCleanRefold(t *testing.T) {
	fc := &fakeCaller{resp: okResponse(t, string(contract.CmdAudit), map[string]any{
		"warranted":          true,
		"ticks_audited":      120,
		"recorded_session":   uint64(0xABCDEF),
		"reproduced_session": uint64(0xABCDEF),
	})}
	cs, ctx := connectSelfHealTools(t, resolveTo(fc))

	res := callTool(t, cs, ctx, "audit", map[string]any{"session_id": "sess-1"})
	if res.IsError {
		t.Fatalf("audit reported a tool error: %s", callText(res))
	}
	if fc.gotCmd != string(contract.CmdAudit) {
		t.Fatalf("audit issued command %q, want %q", fc.gotCmd, contract.CmdAudit)
	}
	if fc.gotArgs != nil {
		t.Fatalf("audit must send no args (whole-run property); sent: %s", fc.gotArgs)
	}

	var out AuditOutput
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode audit output: %v; raw: %s", err, callText(res))
	}
	if !out.Warranted {
		t.Fatal("audit reported warranted=false on a clean re-fold")
	}
	if out.Diverged != nil {
		t.Fatalf("audit carried a divergence on a warranted recording: %+v", out.Diverged)
	}
	if out.TicksAudited != 120 || out.RecordedSession != 0xABCDEF || out.ReproducedSession != 0xABCDEF {
		t.Fatalf("audit verdict summary wrong: %+v", out)
	}
}

// TestAuditDivergenceReportsFirstTick proves a canned divergence surfaces
// warranted=false plus the first diverging tick and the recorded-vs-reproduced
// digest diff (the §28 §3 diverged payload).
func TestAuditDivergenceReportsFirstTick(t *testing.T) {
	fc := &fakeCaller{resp: okResponse(t, string(contract.CmdAudit), map[string]any{
		"warranted":          false,
		"ticks_audited":      55,
		"recorded_session":   uint64(0x1111),
		"reproduced_session": uint64(0x2222),
		"diverged": map[string]any{
			"v":          contract.ProtocolVersion,
			"event":      "diverged",
			"tick":       42,
			"recorded":   uint64(0xDEAD),
			"reproduced": uint64(0xBEEF),
		},
	})}
	cs, ctx := connectSelfHealTools(t, resolveTo(fc))

	res := callTool(t, cs, ctx, "audit", map[string]any{"session_id": "sess-1"})
	if res.IsError {
		t.Fatalf("audit reported a tool error: %s", callText(res))
	}
	var out AuditOutput
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode audit output: %v; raw: %s", err, callText(res))
	}
	if out.Warranted {
		t.Fatal("audit reported warranted=true on a divergence")
	}
	if out.Diverged == nil {
		t.Fatal("audit did not surface the divergence block on warranted=false")
	}
	if out.Diverged.Tick != 42 || out.Diverged.Recorded != 0xDEAD || out.Diverged.Reproduced != 0xBEEF {
		t.Fatalf("audit divergence frame wrong: %+v", out.Diverged)
	}
}

// TestSelfHealUnknownSessionIsStructuredError proves both tools report an unknown
// session id as the structured invalid_input IsError envelope the model reads and
// self-corrects from — not a protocol-level error — before any Call.
func TestSelfHealUnknownSessionIsStructuredError(t *testing.T) {
	miss := func(string) (caller, bool) { return nil, false }
	cs, ctx := connectSelfHealTools(t, miss)

	for _, tc := range []struct {
		tool string
		args map[string]any
	}{
		{"capture_test", map[string]any{"session_id": "ghost", "behavior": "b", "tick": 1}},
		{"audit", map[string]any{"session_id": "ghost"}},
	} {
		res := callTool(t, cs, ctx, tc.tool, tc.args)
		if !res.IsError {
			t.Fatalf("%s did not flag IsError for an unknown session id", tc.tool)
		}
		got := callText(res)
		for _, want := range []string{`"category":"invalid_input"`, "unknown session id: ghost"} {
			if !strings.Contains(got, want) {
				t.Fatalf("%s error envelope missing %q; got: %s", tc.tool, want, got)
			}
		}
	}
}

// TestSelfHealRuntimeErrorResponseIsStructuredError proves a §28 error response
// (ok:false with an error string) surfaces as the structured session IsError
// envelope carrying the runtime's message, so the model sees the command failed
// without the SDK turning it into an unrecoverable protocol error.
func TestSelfHealRuntimeErrorResponseIsStructuredError(t *testing.T) {
	for _, tc := range []struct {
		tool    string
		cmd     contract.Command
		args    map[string]any
		errText string
	}{
		{"capture_test", contract.CmdCaptureTest, map[string]any{"session_id": "s", "behavior": "b", "tick": 1}, "unknown behavior"},
		{"audit", contract.CmdAudit, map[string]any{"session_id": "s"}, "no recording loaded"},
	} {
		errMsg := tc.errText
		fc := &fakeCaller{resp: &contract.Response{
			V:     contract.ProtocolVersion,
			Ok:    false,
			Cmd:   string(tc.cmd),
			Error: &errMsg,
		}}
		cs, ctx := connectSelfHealTools(t, resolveTo(fc))

		res := callTool(t, cs, ctx, tc.tool, tc.args)
		if !res.IsError {
			t.Fatalf("%s did not flag IsError on a §28 error response", tc.tool)
		}
		got := callText(res)
		for _, want := range []string{`"category":"session"`, tc.errText} {
			if !strings.Contains(got, want) {
				t.Fatalf("%s §28-error envelope missing %q; got: %s", tc.tool, want, got)
			}
		}
	}
}

// TestSelfHealToolsAdvertised confirms both self-heal tools appear in tools/list so
// an agent can discover them before calling.
func TestSelfHealToolsAdvertised(t *testing.T) {
	fc := &fakeCaller{resp: okResponse(t, string(contract.CmdAudit), map[string]any{"warranted": true})}
	cs, ctx := connectSelfHealTools(t, resolveTo(fc))

	res, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	want := map[string]bool{"capture_test": false, "audit": false}
	for _, tool := range res.Tools {
		if _, ok := want[tool.Name]; ok {
			want[tool.Name] = true
		}
	}
	for name, seen := range want {
		if !seen {
			t.Fatalf("self-heal tool %q not advertised in tools/list", name)
		}
	}
}
