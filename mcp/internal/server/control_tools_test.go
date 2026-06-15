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

// ctlFakeCaller is the canned §28 caller the control-tool tests drive against — NO
// live runtime. It records the (cmd, args) of the last Call so a test asserts the
// tool sent the right command and the right arg shape, and replays a pre-set
// Response (or err). One ctlFakeCaller stands in for one resolved session.
type ctlFakeCaller struct {
	gotCmd  string
	gotArgs json.RawMessage
	resp    *contract.Response
	err     error
}

func (f *ctlFakeCaller) Call(_ context.Context, cmd string, args json.RawMessage) (*contract.Response, error) {
	f.gotCmd = cmd
	f.gotArgs = args
	return f.resp, f.err
}

// ctlOkResp builds an ok §28 response whose result is the given raw JSON object.
func ctlOkResp(cmd, result string) *contract.Response {
	raw := json.RawMessage(result)
	return &contract.Response{V: contract.ProtocolVersion, ID: 1, Ok: true, Cmd: cmd, Result: &raw}
}

// ctlErrResp builds a not-ok §28 response carrying a runtime refusal message — the
// shape runtime/introspect_control.odin's error_response emits.
func ctlErrResp(cmd, msg string) *contract.Response {
	m := msg
	return &contract.Response{V: contract.ProtocolVersion, ID: 1, Ok: false, Cmd: cmd, Error: &m}
}

// connectControlTools wires a BARE server (no New, so server.go is untouched)
// carrying ONLY the control tools, with the session-resolution seam INJECTED so
// every session id resolves to the supplied fake caller (resolveID match) and any
// other id is "unknown". It returns the connected client and the context.
func connectControlTools(t *testing.T, resolveID string, fake caller) (*mcp.ClientSession, context.Context) {
	t.Helper()
	ctx := context.Background()

	srv := mcp.NewServer(&mcp.Implementation{Name: "funpack-mcp-test", Version: "v0.0.0"}, nil)
	resolve := func(id string) (caller, bool) {
		if id == resolveID {
			return fake, true
		}
		return nil, false
	}
	registerControlToolsWith(srv, zerolog.Nop(), resolve)

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

// controlOutput is the decoded ControlOutput a test asserts against.
type controlOutput struct {
	Cmd    string `json:"cmd"`
	Branch *struct {
		BaseTick int `json:"base_tick"`
		Ticks    int `json:"ticks"`
	} `json:"branch"`
	Active    string          `json:"active"`
	Warranted *bool           `json:"warranted"`
	Result    json.RawMessage `json:"result"`
}

func decodeControl(t *testing.T, res *mcp.CallToolResult) controlOutput {
	t.Helper()
	var out controlOutput
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode control output: %v; raw: %s", err, callText(res))
	}
	return out
}

const controlSessionID = "sess-control-1"

// branchResult is the perturbing-arm success result the runtime renders
// (control_ok_response): a non-warranted branch position. Used as the canned
// reply for inject_input/set/emit/branch (set/emit/branch render exactly this).
const branchResult = `{"branch":{"base_tick":7,"ticks":3},"warranted":false}`

// TestControlToolsSendCmdAndSurfaceBranch is the table covering every PERTURBING
// control arm: each tool sends its §28 command with the right arg keys, and the
// canned non-warranted branch position surfaces in the typed output AND verbatim
// in Result. One case per command keeps each arm's arg shape pinned to the runtime.
func TestControlToolsSendCmdAndSurfaceBranch(t *testing.T) {
	type tc struct {
		tool     string
		args     map[string]any
		wantCmd  contract.Command
		result   string
		wantArgs []string // substrings that MUST appear in the marshalled args the caller saw
	}
	cases := []tc{
		{
			tool:     "control_inject_input",
			args:     map[string]any{"session_id": controlSessionID, "pressed": []any{map[string]any{"player": "P1", "action": "Move::Jump"}}, "ticks": 2},
			wantCmd:  contract.CmdInjectInput,
			result:   branchResult,
			wantArgs: []string{`"pressed"`, `"P1"`, `"Move::Jump"`, `"ticks":2`},
		},
		{
			tool:     "control_set",
			args:     map[string]any{"session_id": controlSessionID, "thing": "Player", "field": "hp", "value": "100", "instance": 4},
			wantCmd:  contract.CmdSet,
			result:   branchResult,
			wantArgs: []string{`"thing":"Player"`, `"field":"hp"`, `"value":"100"`, `"instance":4`},
		},
		{
			tool:     "control_emit",
			args:     map[string]any{"session_id": controlSessionID, "signal": "Damage", "value": "{amount:5}"},
			wantCmd:  contract.CmdEmit,
			result:   branchResult,
			wantArgs: []string{`"signal":"Damage"`, `"value":"{amount:5}"`},
		},
		{
			tool:     "control_reload",
			args:     map[string]any{"session_id": controlSessionID, "artifact": "build/game.fp"},
			wantCmd:  contract.CmdReload,
			result:   `{"branch":{"base_tick":7,"ticks":3},"warranted":false,"swapped":true}`,
			wantArgs: []string{`"artifact":"build/game.fp"`},
		},
		{
			tool:     "control_spawn",
			args:     map[string]any{"session_id": controlSessionID, "thing": "Enemy", "fields": map[string]any{"hp": "10"}},
			wantCmd:  contract.CmdSpawn,
			result:   `{"branch":{"base_tick":7,"ticks":3},"warranted":false,"instance":42}`,
			wantArgs: []string{`"thing":"Enemy"`, `"fields"`, `"hp":"10"`},
		},
		{
			tool:     "control_branch",
			args:     map[string]any{"session_id": controlSessionID, "tick": 5},
			wantCmd:  contract.CmdBranch,
			result:   `{"branch":{"base_tick":5,"ticks":0},"warranted":false}`,
			wantArgs: []string{`"tick":5`},
		},
	}

	for _, c := range cases {
		t.Run(c.tool, func(t *testing.T) {
			fake := &ctlFakeCaller{resp: ctlOkResp(string(c.wantCmd), c.result)}
			cs, ctx := connectControlTools(t, controlSessionID, fake)

			res := callTool(t, cs, ctx, c.tool, c.args)
			if res.IsError {
				t.Fatalf("%s reported a tool error: %s", c.tool, callText(res))
			}

			if fake.gotCmd != string(c.wantCmd) {
				t.Fatalf("%s sent cmd %q, want %q", c.tool, fake.gotCmd, c.wantCmd)
			}
			gotArgs := string(fake.gotArgs)
			for _, want := range c.wantArgs {
				if !strings.Contains(gotArgs, want) {
					t.Fatalf("%s args missing %q; sent: %s", c.tool, want, gotArgs)
				}
			}

			out := decodeControl(t, res)
			if out.Cmd != string(c.wantCmd) {
				t.Fatalf("%s output cmd %q, want %q", c.tool, out.Cmd, c.wantCmd)
			}
			if out.Branch == nil {
				t.Fatalf("%s output did not surface the forked branch position; raw: %s", c.tool, callText(res))
			}
			if out.Warranted == nil || *out.Warranted {
				t.Fatalf("%s did not surface the non-warranted fork (§28 control is never warranted); raw: %s", c.tool, callText(res))
			}
			// The full runtime result passes through verbatim — command-specific fields survive.
			if !strings.Contains(string(out.Result), `"warranted":false`) {
				t.Fatalf("%s did not pass the raw result through; got Result: %s", c.tool, out.Result)
			}
		})
	}
}

// TestControlSpawnSurfacesMintedInstance proves the command-specific field a
// perturbing arm appends (spawn's minted instance id) survives the pass-through —
// the typed view names only the universal fields, but Result carries the rest.
func TestControlSpawnSurfacesMintedInstance(t *testing.T) {
	fake := &ctlFakeCaller{resp: ctlOkResp("spawn", `{"branch":{"base_tick":7,"ticks":4},"warranted":false,"instance":42}`)}
	cs, ctx := connectControlTools(t, controlSessionID, fake)

	res := callTool(t, cs, ctx, "control_spawn", map[string]any{"session_id": controlSessionID, "thing": "Enemy"})
	if res.IsError {
		t.Fatalf("control_spawn reported a tool error: %s", callText(res))
	}
	out := decodeControl(t, res)
	if !strings.Contains(string(out.Result), `"instance":42`) {
		t.Fatalf("control_spawn did not surface the minted instance id in Result; got: %s", out.Result)
	}
}

// TestControlCheckoutSurfacesActiveLineage proves checkout — the lone non-perturbing
// arm — surfaces the now-active lineage and its warranty READ from the runtime
// result, not invented. A canonical checkout surfaces active=canonical, warranted=true.
func TestControlCheckoutSurfacesActiveLineage(t *testing.T) {
	t.Run("branch", func(t *testing.T) {
		fake := &ctlFakeCaller{resp: ctlOkResp("checkout", `{"active":"branch","warranted":false,"branch":{"base_tick":7,"ticks":3}}`)}
		cs, ctx := connectControlTools(t, controlSessionID, fake)

		res := callTool(t, cs, ctx, "control_checkout", map[string]any{"session_id": controlSessionID, "target": "branch"})
		if res.IsError {
			t.Fatalf("control_checkout reported a tool error: %s", callText(res))
		}
		if fake.gotCmd != string(contract.CmdCheckout) {
			t.Fatalf("control_checkout sent cmd %q, want checkout", fake.gotCmd)
		}
		if !strings.Contains(string(fake.gotArgs), `"target":"branch"`) {
			t.Fatalf("control_checkout did not forward target; sent: %s", fake.gotArgs)
		}
		out := decodeControl(t, res)
		if out.Active != "branch" {
			t.Fatalf("control_checkout active lineage: got %q, want branch", out.Active)
		}
		if out.Warranted == nil || *out.Warranted {
			t.Fatalf("a branch checkout must surface warranted=false; raw: %s", callText(res))
		}
	})

	t.Run("canonical", func(t *testing.T) {
		fake := &ctlFakeCaller{resp: ctlOkResp("checkout", `{"active":"canonical","warranted":true}`)}
		cs, ctx := connectControlTools(t, controlSessionID, fake)

		res := callTool(t, cs, ctx, "control_checkout", map[string]any{"session_id": controlSessionID, "target": "canonical"})
		if res.IsError {
			t.Fatalf("control_checkout reported a tool error: %s", callText(res))
		}
		out := decodeControl(t, res)
		if out.Active != "canonical" {
			t.Fatalf("control_checkout active lineage: got %q, want canonical", out.Active)
		}
		if out.Warranted == nil || !*out.Warranted {
			t.Fatalf("a canonical checkout must surface warranted=true (the trunk is warranted); raw: %s", callText(res))
		}
	})
}

// TestControlUnknownSessionIsStructuredError proves a control call against an
// unregistered session id surfaces the structured invalid_input IsError envelope
// the model self-corrects from — and the caller is NEVER reached (no §28 traffic
// for a session that does not exist).
func TestControlUnknownSessionIsStructuredError(t *testing.T) {
	fake := &ctlFakeCaller{resp: ctlOkResp("set", branchResult)}
	cs, ctx := connectControlTools(t, controlSessionID, fake)

	res := callTool(t, cs, ctx, "control_set", map[string]any{"session_id": "no-such-session", "thing": "Player", "field": "hp", "value": "1"})
	if !res.IsError {
		t.Fatal("control_set did not flag IsError for an unknown session id")
	}
	if fake.gotCmd != "" {
		t.Fatalf("control_set reached the caller for an unknown session id (sent %q)", fake.gotCmd)
	}
	got := callText(res)
	for _, want := range []string{`"category":"invalid_input"`, "unknown session id: no-such-session"} {
		if !strings.Contains(got, want) {
			t.Fatalf("control_set error envelope missing %q; got: %s", want, got)
		}
	}
}

// TestControlRuntimeRefusalIsStructuredError proves a §28 not-ok response (a
// runtime control refusal — out-of-range tick, unknown thing, a reload migration
// refusal) maps to a structured invalid_input IsError carrying the runtime's own
// message, NOT a protocol-level error, so the model reads the reason and corrects.
func TestControlRuntimeRefusalIsStructuredError(t *testing.T) {
	fake := &ctlFakeCaller{resp: ctlErrResp("branch", "tick out of range")}
	cs, ctx := connectControlTools(t, controlSessionID, fake)

	res := callTool(t, cs, ctx, "control_branch", map[string]any{"session_id": controlSessionID, "tick": 9999})
	if !res.IsError {
		t.Fatal("control_branch did not flag IsError for a runtime refusal")
	}
	got := callText(res)
	for _, want := range []string{`"category":"invalid_input"`, "tick out of range"} {
		if !strings.Contains(got, want) {
			t.Fatalf("control_branch refusal envelope missing %q; got: %s", want, got)
		}
	}
}

// TestControlToolsAdvertised confirms every control tool appears in tools/list,
// so an agent can discover the full §28 control group before calling.
func TestControlToolsAdvertised(t *testing.T) {
	cs, ctx := connectControlTools(t, controlSessionID, &ctlFakeCaller{resp: ctlOkResp("set", branchResult)})

	res, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	want := map[string]bool{
		"control_inject_input": false,
		"control_set":          false,
		"control_spawn":        false,
		"control_despawn":      false,
		"control_emit":         false,
		"control_reload":       false,
		"control_branch":       false,
		"control_checkout":     false,
	}
	for _, tool := range res.Tools {
		if _, ok := want[tool.Name]; ok {
			want[tool.Name] = true
		}
	}
	for name, seen := range want {
		if !seen {
			t.Fatalf("control tool %q not advertised in tools/list", name)
		}
	}
}
