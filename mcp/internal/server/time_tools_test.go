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

// timeFakeCaller is a §28 caller (satisfies the caller interface) that records the
// command + args it was issued and returns a canned response — so the time tools
// are exercised end to end with NO live funpack runtime. A handler field lets a
// test script per-command replies (e.g. a §28 ok:false refusal).
type timeFakeCaller struct {
	lastCmd  string
	lastArgs json.RawMessage
	handler  func(cmd string, args json.RawMessage) (*contract.Response, error)
}

func (f *timeFakeCaller) Call(_ context.Context, cmd string, args json.RawMessage) (*contract.Response, error) {
	f.lastCmd = cmd
	f.lastArgs = args
	return f.handler(cmd, args)
}

// timeOkResp builds a §28 ok:true response whose result is the marshalled payload —
// the success envelope the runtime would emit for a time command.
func timeOkResp(t *testing.T, cmd string, result any) *contract.Response {
	t.Helper()
	raw, err := json.Marshal(result)
	if err != nil {
		t.Fatalf("marshal canned result for %s: %v", cmd, err)
	}
	msg := json.RawMessage(raw)
	return &contract.Response{V: contract.ProtocolVersion, ID: 1, Ok: true, Cmd: cmd, Result: &msg}
}

// timeErrResp builds a §28 ok:false refusal carrying the runtime's error text — the
// envelope a time command emits when it refuses (e.g. "no timeline loaded").
func timeErrResp(cmd, text string) *contract.Response {
	return &contract.Response{V: contract.ProtocolVersion, ID: 1, Ok: false, Cmd: cmd, Error: &text}
}

// connectTimeTools wires a BARE server (no New, so server.go is untouched)
// carrying ONLY the time tools, registered with the caller-resolution seam INJECTED
// to hand back fake — so every tool drives without a live funpack runtime. Returns
// the connected client, the fake caller the test inspects, and the context.
func connectTimeTools(t *testing.T, fake *timeFakeCaller) (*mcp.ClientSession, context.Context) {
	t.Helper()
	ctx := context.Background()

	resolve := func(id string) (caller, bool) {
		if id == "no-such-session" {
			return nil, false
		}
		return fake, true
	}

	srv := mcp.NewServer(&mcp.Implementation{Name: "funpack-mcp-test", Version: "v0.0.0"}, nil)
	registerTimeToolsWith(srv, zerolog.Nop(), resolve)

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

// positionFake returns a timeFakeCaller that answers every command with an ok:true
// {tick} position payload — the canned reply the position-only commands surface.
func positionFake(tick int64) *timeFakeCaller {
	f := &timeFakeCaller{}
	f.handler = func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		raw, _ := json.Marshal(TimePositionOutput{Tick: tick})
		msg := json.RawMessage(raw)
		return &contract.Response{V: contract.ProtocolVersion, ID: 1, Ok: true, Cmd: cmd, Result: &msg}, nil
	}
	return f
}

// TestTimePositionCommandsIssueRightCmdAndSurfaceTick proves each position-only
// time tool (load/pause/step/reset) issues its exact §28 command name and surfaces
// the canned {tick} result. One table drives all four — the shared
// callTimePosition body is the junction under test.
func TestTimePositionCommandsIssueRightCmdAndSurfaceTick(t *testing.T) {
	cases := []struct {
		tool    string
		wantCmd string
	}{
		{"time_load", string(contract.CmdLoad)},
		{"time_pause", string(contract.CmdPause)},
		{"time_step", string(contract.CmdStep)},
		{"time_reset", string(contract.CmdReset)},
	}
	for _, tc := range cases {
		t.Run(tc.tool, func(t *testing.T) {
			fake := positionFake(7)
			cs, ctx := connectTimeTools(t, fake)

			res := callTool(t, cs, ctx, tc.tool, map[string]any{"session_id": "s1"})
			if res.IsError {
				t.Fatalf("%s reported a tool error: %s", tc.tool, callText(res))
			}
			if fake.lastCmd != tc.wantCmd {
				t.Fatalf("%s issued cmd %q, want %q", tc.tool, fake.lastCmd, tc.wantCmd)
			}
			var out TimePositionOutput
			if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
				t.Fatalf("decode %s output: %v; raw: %s", tc.tool, err, callText(res))
			}
			if out.Tick != 7 {
				t.Fatalf("%s tick: got %d, want 7", tc.tool, out.Tick)
			}
		})
	}
}

// TestTimeRunDefaultSendsNoUntil proves time_run without an until folds to the last
// recorded tick: it issues the run command with NO args object (the runtime's
// default), and surfaces the canned tick.
func TestTimeRunDefaultSendsNoUntil(t *testing.T) {
	fake := positionFake(42)
	cs, ctx := connectTimeTools(t, fake)

	res := callTool(t, cs, ctx, "time_run", map[string]any{"session_id": "s1"})
	if res.IsError {
		t.Fatalf("time_run reported a tool error: %s", callText(res))
	}
	if fake.lastCmd != string(contract.CmdRun) {
		t.Fatalf("time_run issued cmd %q, want %q", fake.lastCmd, contract.CmdRun)
	}
	if fake.lastArgs != nil {
		t.Fatalf("time_run with no until sent args %s, want nil", string(fake.lastArgs))
	}
	var out TimePositionOutput
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode time_run output: %v", err)
	}
	if out.Tick != 42 {
		t.Fatalf("time_run tick: got %d, want 42", out.Tick)
	}
}

// TestTimeRunWithUntilMarshalsTarget proves time_run with an until issues the run
// command carrying {"until":N} — the synchronous run target the runtime folds to.
func TestTimeRunWithUntilMarshalsTarget(t *testing.T) {
	fake := positionFake(100)
	cs, ctx := connectTimeTools(t, fake)

	res := callTool(t, cs, ctx, "time_run", map[string]any{"session_id": "s1", "until": 100})
	if res.IsError {
		t.Fatalf("time_run reported a tool error: %s", callText(res))
	}
	if fake.lastCmd != string(contract.CmdRun) {
		t.Fatalf("time_run issued cmd %q, want %q", fake.lastCmd, contract.CmdRun)
	}
	var sent struct {
		Until int64 `json:"until"`
	}
	if err := json.Unmarshal(fake.lastArgs, &sent); err != nil {
		t.Fatalf("decode run args: %v; raw: %s", err, string(fake.lastArgs))
	}
	if sent.Until != 100 {
		t.Fatalf("time_run sent until %d, want 100", sent.Until)
	}
}

// TestTimeRewindIssuesTickAndSurfacesReplayShape proves time_rewind issues the
// rewind command carrying the required {"tick":N} and surfaces the full
// bounded-replay result (tick, restored_from, refolded).
func TestTimeRewindIssuesTickAndSurfacesReplayShape(t *testing.T) {
	fake := &timeFakeCaller{}
	fake.handler = func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		return timeOkResp(t, cmd, TimeRewindOutput{Tick: 20, RestoredFrom: 16, Refolded: 4}), nil
	}
	cs, ctx := connectTimeTools(t, fake)

	res := callTool(t, cs, ctx, "time_rewind", map[string]any{"session_id": "s1", "tick": 20})
	if res.IsError {
		t.Fatalf("time_rewind reported a tool error: %s", callText(res))
	}
	if fake.lastCmd != string(contract.CmdRewind) {
		t.Fatalf("time_rewind issued cmd %q, want %q", fake.lastCmd, contract.CmdRewind)
	}
	var sent struct {
		Tick int64 `json:"tick"`
	}
	if err := json.Unmarshal(fake.lastArgs, &sent); err != nil {
		t.Fatalf("decode rewind args: %v; raw: %s", err, string(fake.lastArgs))
	}
	if sent.Tick != 20 {
		t.Fatalf("time_rewind sent tick %d, want 20", sent.Tick)
	}
	var out TimeRewindOutput
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode time_rewind output: %v; raw: %s", err, callText(res))
	}
	if out.Tick != 20 || out.RestoredFrom != 16 || out.Refolded != 4 {
		t.Fatalf("time_rewind result wrong: %+v", out)
	}
}

// TestTimeStatusParsesFixedPayload proves time_status issues the status command
// and parses the full fixed payload — load state, cursor tick, recording extent,
// seededness, cadence, the ring shape, and the active branch lineage.
func TestTimeStatusParsesFixedPayload(t *testing.T) {
	oldest := int64(0)
	newest := int64(32)
	tick := int64(20)
	want := TimeStatusOutput{
		Loaded:        true,
		Tick:          &tick,
		TicksRecorded: 64,
		Seeded:        true,
		Cadence:       16,
		Ring:          TimeStatusRing{Slots: 32, Occupied: 3, Oldest: &oldest, Newest: &newest},
		Branch:        TimeStatusBranch{Live: false, Active: "canonical"},
	}
	fake := &timeFakeCaller{}
	fake.handler = func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		return timeOkResp(t, cmd, want), nil
	}
	cs, ctx := connectTimeTools(t, fake)

	res := callTool(t, cs, ctx, "time_status", map[string]any{"session_id": "s1"})
	if res.IsError {
		t.Fatalf("time_status reported a tool error: %s", callText(res))
	}
	if fake.lastCmd != string(contract.CmdStatus) {
		t.Fatalf("time_status issued cmd %q, want %q", fake.lastCmd, contract.CmdStatus)
	}
	var out TimeStatusOutput
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode time_status output: %v; raw: %s", err, callText(res))
	}
	if !out.Loaded || out.Tick == nil || *out.Tick != 20 {
		t.Fatalf("time_status load/tick wrong: %+v", out)
	}
	if out.TicksRecorded != 64 || !out.Seeded || out.Cadence != 16 {
		t.Fatalf("time_status extent/seed/cadence wrong: %+v", out)
	}
	if out.Ring.Slots != 32 || out.Ring.Occupied != 3 || out.Ring.Oldest == nil || *out.Ring.Oldest != 0 || out.Ring.Newest == nil || *out.Ring.Newest != 32 {
		t.Fatalf("time_status ring wrong: %+v", out.Ring)
	}
	if out.Branch.Live || out.Branch.Active != "canonical" {
		t.Fatalf("time_status branch wrong: %+v", out.Branch)
	}
}

// TestTimeStatusNullTickWhenUnloaded proves time_status decodes a null cursor tick
// (the runtime emits "tick":null when no timeline is loaded) as a nil pointer
// rather than a zero tick — the unloaded shape is distinguishable from tick 0.
func TestTimeStatusNullTickWhenUnloaded(t *testing.T) {
	fake := &timeFakeCaller{}
	fake.handler = func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		// Hand-built so tick is JSON null, not omitted.
		raw := json.RawMessage(`{"loaded":false,"tick":null,"ticks_recorded":0,"seeded":false,"cadence":16,"ring":{"slots":32,"occupied":0,"oldest":null,"newest":null},"branch":{"live":false,"active":"canonical"}}`)
		return &contract.Response{V: contract.ProtocolVersion, ID: 1, Ok: true, Cmd: cmd, Result: &raw}, nil
	}
	cs, ctx := connectTimeTools(t, fake)

	res := callTool(t, cs, ctx, "time_status", map[string]any{"session_id": "s1"})
	if res.IsError {
		t.Fatalf("time_status reported a tool error: %s", callText(res))
	}
	var out TimeStatusOutput
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode time_status output: %v; raw: %s", err, callText(res))
	}
	if out.Loaded {
		t.Fatalf("time_status loaded should be false, got true")
	}
	if out.Tick != nil {
		t.Fatalf("time_status tick should be nil when unloaded, got %d", *out.Tick)
	}
	if out.Ring.Oldest != nil || out.Ring.Newest != nil {
		t.Fatalf("empty ring oldest/newest should be nil: %+v", out.Ring)
	}
}

// TestTimeToolUnknownSessionIsStructuredError proves a time tool naming an
// unregistered session id surfaces the structured invalid_input IsError envelope
// the model self-corrects from — never a protocol-level error, never a caller hit.
// One assertion per tool (every tool shares the resolve-then-error junction).
func TestTimeToolUnknownSessionIsStructuredError(t *testing.T) {
	tools := []struct {
		name string
		args map[string]any
	}{
		{"time_load", map[string]any{"session_id": "no-such-session"}},
		{"time_run", map[string]any{"session_id": "no-such-session"}},
		{"time_pause", map[string]any{"session_id": "no-such-session"}},
		{"time_step", map[string]any{"session_id": "no-such-session"}},
		{"time_rewind", map[string]any{"session_id": "no-such-session", "tick": 5}},
		{"time_reset", map[string]any{"session_id": "no-such-session"}},
		{"time_status", map[string]any{"session_id": "no-such-session"}},
	}
	for _, tc := range tools {
		t.Run(tc.name, func(t *testing.T) {
			// A panicking caller proves the unknown-id guard short-circuits before Call.
			fake := &timeFakeCaller{handler: func(string, json.RawMessage) (*contract.Response, error) {
				t.Fatal("caller must not be reached for an unknown session id")
				return nil, nil
			}}
			cs, ctx := connectTimeTools(t, fake)

			res := callTool(t, cs, ctx, tc.name, tc.args)
			if !res.IsError {
				t.Fatalf("%s did not flag IsError for an unknown session id", tc.name)
			}
			got := callText(res)
			for _, want := range []string{`"category":"invalid_input"`, "unknown session id: no-such-session"} {
				if !strings.Contains(got, want) {
					t.Fatalf("%s error envelope missing %q; got: %s", tc.name, want, got)
				}
			}
		})
	}
}

// TestTimeRefusalSurfacesAsSessionError proves a §28 ok:false response (a runtime
// refusal — e.g. running before load) surfaces as a session-category IsError
// envelope carrying the runtime's error text, so the model reads the refusal reason
// and self-corrects (issue load first) rather than getting an opaque failure.
func TestTimeRefusalSurfacesAsSessionError(t *testing.T) {
	fake := &timeFakeCaller{}
	fake.handler = func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		return timeErrResp(cmd, "no timeline loaded — issue load first"), nil
	}
	cs, ctx := connectTimeTools(t, fake)

	res := callTool(t, cs, ctx, "time_step", map[string]any{"session_id": "s1"})
	if !res.IsError {
		t.Fatal("time_step did not flag IsError for a §28 ok:false refusal")
	}
	got := callText(res)
	for _, want := range []string{`"category":"session"`, "no timeline loaded — issue load first"} {
		if !strings.Contains(got, want) {
			t.Fatalf("time_step refusal envelope missing %q; got: %s", want, got)
		}
	}
}

// TestTimeRewindRefusalSurfacesText proves rewind's §28 refusal (e.g. an
// out-of-range target) surfaces the runtime error text — the rewind path maps
// ok:false through the same session-error junction as the position commands.
func TestTimeRewindRefusalSurfacesText(t *testing.T) {
	fake := &timeFakeCaller{}
	fake.handler = func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		return timeErrResp(cmd, "tick out of range"), nil
	}
	cs, ctx := connectTimeTools(t, fake)

	res := callTool(t, cs, ctx, "time_rewind", map[string]any{"session_id": "s1", "tick": 9999})
	if !res.IsError {
		t.Fatal("time_rewind did not flag IsError for an out-of-range refusal")
	}
	if got := callText(res); !strings.Contains(got, "tick out of range") || !strings.Contains(got, `"category":"session"`) {
		t.Fatalf("time_rewind refusal envelope wrong; got: %s", got)
	}
}

// TestTimeToolsAdvertised confirms all seven §28 time tools appear in tools/list,
// so an agent can discover the whole group before calling.
func TestTimeToolsAdvertised(t *testing.T) {
	cs, ctx := connectTimeTools(t, positionFake(0))

	res, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	want := map[string]bool{
		"time_load": false, "time_run": false, "time_pause": false, "time_step": false,
		"time_rewind": false, "time_reset": false, "time_status": false,
	}
	for _, tool := range res.Tools {
		if _, ok := want[tool.Name]; ok {
			want[tool.Name] = true
		}
	}
	for name, seen := range want {
		if !seen {
			t.Fatalf("time tool %q not advertised in tools/list", name)
		}
	}
}
