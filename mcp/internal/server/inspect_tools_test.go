package server

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"image/png"
	"strings"
	"testing"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// inspectFakeCaller is a §28 caller (satisfies the caller interface) that records
// the command + args it was issued and returns a canned response — so the inspect
// tools are exercised end to end with NO live funpack runtime. The handler lets a
// test script per-command replies (an ok payload or a §28 ok:false refusal).
type inspectFakeCaller struct {
	lastCmd  string
	lastArgs json.RawMessage
	handler  func(cmd string, args json.RawMessage) (*contract.Response, error)
}

func (f *inspectFakeCaller) Call(_ context.Context, cmd string, args json.RawMessage) (*contract.Response, error) {
	f.lastCmd = cmd
	f.lastArgs = args
	return f.handler(cmd, args)
}

// inspectOkResp builds a §28 ok:true response whose result is the marshalled
// payload — the success envelope the runtime would emit for an observe command.
func inspectOkResp(t *testing.T, cmd string, result any) *contract.Response {
	t.Helper()
	raw, err := json.Marshal(result)
	if err != nil {
		t.Fatalf("marshal canned result for %s: %v", cmd, err)
	}
	msg := json.RawMessage(raw)
	return &contract.Response{V: contract.ProtocolVersion, ID: 1, Ok: true, Cmd: cmd, Result: &msg}
}

// inspectErrResp builds a §28 ok:false refusal carrying the runtime's error text —
// the envelope an observe command emits when it refuses (e.g. "tick out of range").
func inspectErrResp(cmd, text string) *contract.Response {
	return &contract.Response{V: contract.ProtocolVersion, ID: 1, Ok: false, Cmd: cmd, Error: &text}
}

// connectInspectTools wires a BARE server (no New, so server.go is untouched)
// carrying ONLY the inspect tools, registered with the caller-resolution seam
// INJECTED to hand back fake — so every tool drives without a live funpack runtime.
// The id "no-such-session" resolves to a miss, every other id to the fake.
func connectInspectTools(t *testing.T, fake *inspectFakeCaller) (*mcp.ClientSession, context.Context) {
	t.Helper()
	ctx := context.Background()

	resolve := func(id string) (caller, bool) {
		if id == "no-such-session" {
			return nil, false
		}
		return fake, true
	}

	srv := mcp.NewServer(&mcp.Implementation{Name: "funpack-mcp-test", Version: "v0.0.0"}, nil)
	registerInspectToolsWith(srv, zerolog.Nop(), resolve)

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

// TestInspectToolsAdvertised confirms all seven §28 inspect tools appear in
// tools/list, so an agent can discover the whole group before calling.
func TestInspectToolsAdvertised(t *testing.T) {
	fake := &inspectFakeCaller{handler: func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		return inspectOkResp(t, cmd, map[string]any{}), nil
	}}
	cs, ctx := connectInspectTools(t, fake)

	res, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	want := map[string]bool{
		"inspect_signals": false, "inspect_pipeline": false, "inspect_trace": false,
		"inspect_diff": false, "inspect_replay_behavior": false, "inspect_draw_list": false,
		"inspect_screenshot": false,
	}
	for _, tool := range res.Tools {
		if _, ok := want[tool.Name]; ok {
			want[tool.Name] = true
		}
	}
	for name, seen := range want {
		if !seen {
			t.Fatalf("inspect tool %q not advertised in tools/list", name)
		}
	}
}

// TestInspectToolUnknownSessionIsStructuredError proves an inspect tool naming an
// unregistered session id surfaces the structured invalid_input IsError envelope —
// never a protocol-level error, never a caller hit. One case per tool (every tool
// shares the resolve-then-error junction, screenshot included).
func TestInspectToolUnknownSessionIsStructuredError(t *testing.T) {
	tools := []struct {
		name string
		args map[string]any
	}{
		{"inspect_signals", map[string]any{"session_id": "no-such-session", "tick": 1}},
		{"inspect_pipeline", map[string]any{"session_id": "no-such-session"}},
		{"inspect_trace", map[string]any{"session_id": "no-such-session", "tick": 1, "behavior": "move"}},
		{"inspect_diff", map[string]any{"session_id": "no-such-session", "from": 0, "to": 1}},
		{"inspect_replay_behavior", map[string]any{"session_id": "no-such-session", "tick": 1, "behavior": "move"}},
		{"inspect_draw_list", map[string]any{"session_id": "no-such-session", "tick": 1}},
		{"inspect_screenshot", map[string]any{"session_id": "no-such-session", "tick": 1}},
	}
	for _, tc := range tools {
		t.Run(tc.name, func(t *testing.T) {
			// A panicking caller proves the unknown-id guard short-circuits before Call.
			fake := &inspectFakeCaller{handler: func(string, json.RawMessage) (*contract.Response, error) {
				t.Fatal("caller must not be reached for an unknown session id")
				return nil, nil
			}}
			cs, ctx := connectInspectTools(t, fake)

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

// TestInspectSignalsMarshalsTickAndDecodesRoutes proves inspect_signals issues the
// signals command carrying {tick} and decodes the routes (a broadcast route with a
// null target, a per-instance route with a target Id) — the §28 dataflow shape.
func TestInspectSignalsMarshalsTickAndDecodesRoutes(t *testing.T) {
	target := int64(7)
	want := SignalsOutput{
		Tick: 12,
		Routes: []SignalRoute{
			{Signal: "Damage", Target: nil, Values: []string{"Damage(amount=5)"}},
			{Signal: "Heal", Target: &target, Values: []string{"Heal(amount=2)"}},
		},
	}
	fake := &inspectFakeCaller{handler: func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		return inspectOkResp(t, cmd, want), nil
	}}
	cs, ctx := connectInspectTools(t, fake)

	res := callTool(t, cs, ctx, "inspect_signals", map[string]any{"session_id": "s1", "tick": 12})
	if res.IsError {
		t.Fatalf("inspect_signals reported a tool error: %s", callText(res))
	}
	if fake.lastCmd != string(contract.CmdSignals) {
		t.Fatalf("inspect_signals issued cmd %q, want %q", fake.lastCmd, contract.CmdSignals)
	}
	var sent struct {
		Tick int64 `json:"tick"`
	}
	if err := json.Unmarshal(fake.lastArgs, &sent); err != nil {
		t.Fatalf("decode signals args: %v; raw: %s", err, string(fake.lastArgs))
	}
	if sent.Tick != 12 {
		t.Fatalf("inspect_signals sent tick %d, want 12", sent.Tick)
	}
	var out SignalsOutput
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode inspect_signals output: %v; raw: %s", err, callText(res))
	}
	if out.Tick != 12 || len(out.Routes) != 2 {
		t.Fatalf("inspect_signals shape wrong: %+v", out)
	}
	if out.Routes[0].Target != nil {
		t.Fatalf("broadcast route should have null target, got %v", *out.Routes[0].Target)
	}
	if out.Routes[1].Target == nil || *out.Routes[1].Target != 7 {
		t.Fatalf("per-instance route target wrong: %+v", out.Routes[1])
	}
}

// TestInspectPipelineSendsNoTickAndDecodesSteps proves inspect_pipeline issues the
// pipeline command with NO tick arg (a pure program read) and decodes the flattened
// total order.
func TestInspectPipelineSendsNoTickAndDecodesSteps(t *testing.T) {
	want := PipelineOutput{Steps: []PipelineStep{
		{Ordinal: 0, Stage: "input", Behavior: "read_pad"},
		{Ordinal: 1, Stage: "simulate", Behavior: "move"},
	}}
	fake := &inspectFakeCaller{handler: func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		return inspectOkResp(t, cmd, want), nil
	}}
	cs, ctx := connectInspectTools(t, fake)

	res := callTool(t, cs, ctx, "inspect_pipeline", map[string]any{"session_id": "s1"})
	if res.IsError {
		t.Fatalf("inspect_pipeline reported a tool error: %s", callText(res))
	}
	if fake.lastCmd != string(contract.CmdPipeline) {
		t.Fatalf("inspect_pipeline issued cmd %q, want %q", fake.lastCmd, contract.CmdPipeline)
	}
	// With no branch and no tick, the marshalled args carry neither key.
	if got := string(fake.lastArgs); got != "{}" {
		t.Fatalf("inspect_pipeline sent args %q, want empty object", got)
	}
	var out PipelineOutput
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode inspect_pipeline output: %v; raw: %s", err, callText(res))
	}
	if len(out.Steps) != 2 || out.Steps[1].Behavior != "move" {
		t.Fatalf("inspect_pipeline steps wrong: %+v", out.Steps)
	}
}

// TestInspectTraceMarshalsTickBehaviorAndDecodesSteps proves inspect_trace issues
// the trace command carrying {tick, behavior} and decodes the per-instance step
// shape, including the null self_after of a despawned instance.
func TestInspectTraceMarshalsTickBehaviorAndDecodesSteps(t *testing.T) {
	selfAfter := "Ball(x=3,y=4)"
	want := TraceOutput{
		Tick:     8,
		Behavior: "bounce",
		Steps: []TraceStep{
			{Ordinal: 2, Instance: 0, SelfBefore: "Ball(x=2,y=4)", Reads: map[string]string{"wall": "Wall(side=L)"}, Ok: true, Result: "Vec2(1,0)", SelfAfter: &selfAfter},
			{Ordinal: 2, Instance: 1, SelfBefore: "Ball(x=9,y=4)", Reads: map[string]string{}, Ok: true, Result: "Vec2(0,0)", SelfAfter: nil},
		},
	}
	fake := &inspectFakeCaller{handler: func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		return inspectOkResp(t, cmd, want), nil
	}}
	cs, ctx := connectInspectTools(t, fake)

	res := callTool(t, cs, ctx, "inspect_trace", map[string]any{"session_id": "s1", "tick": 8, "behavior": "bounce"})
	if res.IsError {
		t.Fatalf("inspect_trace reported a tool error: %s", callText(res))
	}
	if fake.lastCmd != string(contract.CmdTrace) {
		t.Fatalf("inspect_trace issued cmd %q, want %q", fake.lastCmd, contract.CmdTrace)
	}
	var sent struct {
		Tick     int64  `json:"tick"`
		Behavior string `json:"behavior"`
	}
	if err := json.Unmarshal(fake.lastArgs, &sent); err != nil {
		t.Fatalf("decode trace args: %v; raw: %s", err, string(fake.lastArgs))
	}
	if sent.Tick != 8 || sent.Behavior != "bounce" {
		t.Fatalf("inspect_trace sent {tick:%d,behavior:%q}, want {8,bounce}", sent.Tick, sent.Behavior)
	}
	var out TraceOutput
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode inspect_trace output: %v; raw: %s", err, callText(res))
	}
	if out.Behavior != "bounce" || len(out.Steps) != 2 {
		t.Fatalf("inspect_trace shape wrong: %+v", out)
	}
	if out.Steps[0].SelfAfter == nil || *out.Steps[0].SelfAfter != "Ball(x=3,y=4)" {
		t.Fatalf("step 0 self_after wrong: %+v", out.Steps[0])
	}
	if out.Steps[1].SelfAfter != nil {
		t.Fatalf("despawned step 1 self_after should be null, got %q", *out.Steps[1].SelfAfter)
	}
}

// TestInspectDiffMarshalsFromToAndDecodesTables proves inspect_diff issues the diff
// command carrying {from, to} and decodes the per-table delta — added rows, removed
// Ids, and a changed row whose field carries a null "from" (a column absent at the
// earlier tick).
func TestInspectDiffMarshalsFromToAndDecodesTables(t *testing.T) {
	want := DiffOutput{
		From: 1, To: 5,
		Tables: []DiffTable{{
			Thing:   "Ball",
			Added:   []DiffAddedRow{{ID: 2, Row: "Ball(x=0,y=0)"}},
			Removed: []int64{9},
			Changed: []DiffChangedRow{{ID: 0, Fields: []DiffField{{Field: "vx", From: nil, To: "5"}}}},
		}},
	}
	fake := &inspectFakeCaller{handler: func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		return inspectOkResp(t, cmd, want), nil
	}}
	cs, ctx := connectInspectTools(t, fake)

	res := callTool(t, cs, ctx, "inspect_diff", map[string]any{"session_id": "s1", "from": 1, "to": 5})
	if res.IsError {
		t.Fatalf("inspect_diff reported a tool error: %s", callText(res))
	}
	if fake.lastCmd != string(contract.CmdDiff) {
		t.Fatalf("inspect_diff issued cmd %q, want %q", fake.lastCmd, contract.CmdDiff)
	}
	var sent struct {
		From int64 `json:"from"`
		To   int64 `json:"to"`
	}
	if err := json.Unmarshal(fake.lastArgs, &sent); err != nil {
		t.Fatalf("decode diff args: %v; raw: %s", err, string(fake.lastArgs))
	}
	if sent.From != 1 || sent.To != 5 {
		t.Fatalf("inspect_diff sent {from:%d,to:%d}, want {1,5}", sent.From, sent.To)
	}
	var out DiffOutput
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode inspect_diff output: %v; raw: %s", err, callText(res))
	}
	if len(out.Tables) != 1 || out.Tables[0].Thing != "Ball" {
		t.Fatalf("inspect_diff tables wrong: %+v", out.Tables)
	}
	tbl := out.Tables[0]
	if len(tbl.Added) != 1 || tbl.Added[0].ID != 2 || len(tbl.Removed) != 1 || tbl.Removed[0] != 9 {
		t.Fatalf("inspect_diff added/removed wrong: %+v", tbl)
	}
	if len(tbl.Changed) != 1 || tbl.Changed[0].Fields[0].From != nil || tbl.Changed[0].Fields[0].To != "5" {
		t.Fatalf("inspect_diff changed field wrong: %+v", tbl.Changed)
	}
}

// TestInspectReplayBehaviorDecodesPurityVerdict proves inspect_replay_behavior
// issues the replay_behavior command and decodes the per-instance purity verdict —
// a refold_matches=false instance is the surfaced §28 §1 violation.
func TestInspectReplayBehaviorDecodesPurityVerdict(t *testing.T) {
	want := ReplayBehaviorOutput{
		Tick: 3, Behavior: "move",
		Instances: []ReplayInstance{
			{Instance: 0, Ok: true, Result: "Vec2(1,0)", RefoldMatches: true},
			{Instance: 1, Ok: true, Result: "Vec2(0,1)", RefoldMatches: false},
		},
	}
	fake := &inspectFakeCaller{handler: func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		return inspectOkResp(t, cmd, want), nil
	}}
	cs, ctx := connectInspectTools(t, fake)

	res := callTool(t, cs, ctx, "inspect_replay_behavior", map[string]any{"session_id": "s1", "tick": 3, "behavior": "move"})
	if res.IsError {
		t.Fatalf("inspect_replay_behavior reported a tool error: %s", callText(res))
	}
	if fake.lastCmd != string(contract.CmdReplayBehavior) {
		t.Fatalf("inspect_replay_behavior issued cmd %q, want %q", fake.lastCmd, contract.CmdReplayBehavior)
	}
	var out ReplayBehaviorOutput
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode inspect_replay_behavior output: %v; raw: %s", err, callText(res))
	}
	if len(out.Instances) != 2 || out.Instances[0].RefoldMatches != true || out.Instances[1].RefoldMatches != false {
		t.Fatalf("inspect_replay_behavior verdicts wrong: %+v", out.Instances)
	}
}

// TestInspectDrawListMarshalsTickAndDecodesCommands proves inspect_draw_list issues
// the draw_list command carrying {tick} and decodes the text commands — the
// sim-pure render projection.
func TestInspectDrawListMarshalsTickAndDecodesCommands(t *testing.T) {
	want := DrawListOutput{Tick: 4, Commands: []string{"Clear(color=Black)", "Rect(at=Vec2(1,2),w=3,h=4)"}}
	fake := &inspectFakeCaller{handler: func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		return inspectOkResp(t, cmd, want), nil
	}}
	cs, ctx := connectInspectTools(t, fake)

	res := callTool(t, cs, ctx, "inspect_draw_list", map[string]any{"session_id": "s1", "tick": 4})
	if res.IsError {
		t.Fatalf("inspect_draw_list reported a tool error: %s", callText(res))
	}
	if fake.lastCmd != string(contract.CmdDrawList) {
		t.Fatalf("inspect_draw_list issued cmd %q, want %q", fake.lastCmd, contract.CmdDrawList)
	}
	var sent struct {
		Tick int64 `json:"tick"`
	}
	if err := json.Unmarshal(fake.lastArgs, &sent); err != nil {
		t.Fatalf("decode draw_list args: %v; raw: %s", err, string(fake.lastArgs))
	}
	if sent.Tick != 4 {
		t.Fatalf("inspect_draw_list sent tick %d, want 4", sent.Tick)
	}
	var out DrawListOutput
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode inspect_draw_list output: %v; raw: %s", err, callText(res))
	}
	if out.Tick != 4 || len(out.Commands) != 2 {
		t.Fatalf("inspect_draw_list shape wrong: %+v", out)
	}
}

// TestInspectBranchSelectorThreadsThrough proves an observe command with the
// optional branch selector set threads it into the §28 args — the observe-addressing
// half (absent ⇒ canonical, set ⇒ a checkout-created branch).
func TestInspectBranchSelectorThreadsThrough(t *testing.T) {
	fake := &inspectFakeCaller{handler: func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		return inspectOkResp(t, cmd, DrawListOutput{Tick: 2, Commands: nil}), nil
	}}
	cs, ctx := connectInspectTools(t, fake)

	res := callTool(t, cs, ctx, "inspect_draw_list", map[string]any{"session_id": "s1", "tick": 2, "branch": "experiment"})
	if res.IsError {
		t.Fatalf("inspect_draw_list reported a tool error: %s", callText(res))
	}
	var sent struct {
		Tick   int64  `json:"tick"`
		Branch string `json:"branch"`
	}
	if err := json.Unmarshal(fake.lastArgs, &sent); err != nil {
		t.Fatalf("decode draw_list args: %v; raw: %s", err, string(fake.lastArgs))
	}
	if sent.Branch != "experiment" {
		t.Fatalf("inspect_draw_list did not thread branch selector; sent args: %s", string(fake.lastArgs))
	}
}

// TestInspectRefusalSurfacesAsSessionError proves a §28 ok:false response (a runtime
// refusal — e.g. an out-of-range tick) surfaces as a session-category IsError
// envelope carrying the runtime's error text, so the model reads the refusal and
// self-corrects. The screenshot refusal path is asserted separately below.
func TestInspectRefusalSurfacesAsSessionError(t *testing.T) {
	fake := &inspectFakeCaller{handler: func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		return inspectErrResp(cmd, "tick out of range"), nil
	}}
	cs, ctx := connectInspectTools(t, fake)

	res := callTool(t, cs, ctx, "inspect_signals", map[string]any{"session_id": "s1", "tick": 9999})
	if !res.IsError {
		t.Fatal("inspect_signals did not flag IsError for a §28 ok:false refusal")
	}
	got := callText(res)
	for _, want := range []string{`"category":"session"`, "tick out of range"} {
		if !strings.Contains(got, want) {
			t.Fatalf("inspect_signals refusal envelope missing %q; got: %s", want, got)
		}
	}
}

// --- screenshot transcode path -----------------------------------------------

// buildQOI assembles a minimal valid QOI byte stream for a width*height image whose
// pixels are all opaque red — exercising the QOI_OP_RGBA op plus a run. It mirrors
// the runtime's 4-channel RGBA32 encode so the screenshot tool's QOI→PNG transcode
// runs over a realistic payload.
func buildQOI(width, height int) []byte {
	var buf bytes.Buffer
	// 14-byte header: "qoif", width, height, channels=4, colorspace=0.
	buf.WriteString("qoif")
	var wh [4]byte
	binary.BigEndian.PutUint32(wh[:], uint32(width))
	buf.Write(wh[:])
	binary.BigEndian.PutUint32(wh[:], uint32(height))
	buf.Write(wh[:])
	buf.WriteByte(4) // channels: RGBA
	buf.WriteByte(0) // colorspace: sRGB

	total := width * height
	// First pixel: QOI_OP_RGBA (255,0,0,255) — opaque red.
	buf.Write([]byte{0xFF, 255, 0, 0, 255})
	// Remaining pixels: QOI_OP_RUN chunks (max run 62 per chunk).
	remaining := total - 1
	for remaining > 0 {
		n := remaining
		if n > 62 {
			n = 62
		}
		buf.WriteByte(0xC0 | byte(n-1)) // QOI_OP_RUN, length n (bias -1)
		remaining -= n
	}
	// 8-byte end marker.
	buf.Write([]byte{0, 0, 0, 0, 0, 0, 0, 1})
	return buf.Bytes()
}

// firstImageContent returns the first ImageContent block of a tool result, or nil.
func firstImageContent(res *mcp.CallToolResult) *mcp.ImageContent {
	for _, c := range res.Content {
		if ic, ok := c.(*mcp.ImageContent); ok {
			return ic
		}
	}
	return nil
}

// TestInspectScreenshotEmitsPNGImageAndMetadata proves inspect_screenshot decodes a
// canned §28 QOI payload, re-encodes it to PNG, and emits BOTH an MCP image content
// block (the visible frame) AND the structured metadata (tick/width/height +
// draw-list). The PNG is decoded back to assert the dimensions survived the
// QOI→RGBA→PNG transcode — a wrong decode would be a wrong image the model trusts.
func TestInspectScreenshotEmitsPNGImageAndMetadata(t *testing.T) {
	const w, h = 4, 3
	qoiPayload := base64.StdEncoding.EncodeToString(buildQOI(w, h))
	canned := screenshotResult{
		Tick: 6, Width: w, Height: h, Format: "qoi", Pixels: qoiPayload,
		Commands: []string{"Clear(color=Black)"},
	}
	fake := &inspectFakeCaller{handler: func(cmd string, args json.RawMessage) (*contract.Response, error) {
		// The include_drawlist flag must reach the runtime as an arg.
		var sent struct {
			IncludeDrawlist *bool `json:"include_drawlist"`
		}
		_ = json.Unmarshal(args, &sent)
		if sent.IncludeDrawlist == nil || !*sent.IncludeDrawlist {
			t.Fatalf("inspect_screenshot did not forward include_drawlist=true; args: %s", string(args))
		}
		return inspectOkResp(t, cmd, canned), nil
	}}
	cs, ctx := connectInspectTools(t, fake)

	include := true
	res := callTool(t, cs, ctx, "inspect_screenshot", map[string]any{
		"session_id": "s1", "tick": 6, "include_drawlist": include,
	})
	if res.IsError {
		t.Fatalf("inspect_screenshot reported a tool error: %s", callText(res))
	}
	if fake.lastCmd != string(contract.CmdScreenshot) {
		t.Fatalf("inspect_screenshot issued cmd %q, want %q", fake.lastCmd, contract.CmdScreenshot)
	}

	// The image content block must be present and decode to a w*h PNG.
	img := firstImageContent(res)
	if img == nil {
		t.Fatalf("inspect_screenshot did not emit an image content block; content: %+v", res.Content)
	}
	if img.MIMEType != "image/png" {
		t.Fatalf("inspect_screenshot image MIME %q, want image/png", img.MIMEType)
	}
	decoded, err := png.Decode(bytes.NewReader(img.Data))
	if err != nil {
		t.Fatalf("inspect_screenshot PNG did not decode: %v", err)
	}
	if b := decoded.Bounds(); b.Dx() != w || b.Dy() != h {
		t.Fatalf("inspect_screenshot PNG dims %dx%d, want %dx%d", b.Dx(), b.Dy(), w, h)
	}
	// The decoded frame is opaque red (the QOI payload's single color).
	r, g, b, a := decoded.At(0, 0).RGBA()
	if r>>8 != 255 || g>>8 != 0 || b>>8 != 0 || a>>8 != 255 {
		t.Fatalf("inspect_screenshot pixel (0,0) = (%d,%d,%d,%d), want opaque red", r>>8, g>>8, b>>8, a>>8)
	}

	// The structured metadata travels as a TextContent block (the SDK leaves our
	// pre-set Content intact and still marshals the typed Out into StructuredContent;
	// we also include the metadata as text so callText sees it).
	var meta ScreenshotOutput
	if err := json.Unmarshal([]byte(callText(res)), &meta); err != nil {
		t.Fatalf("decode inspect_screenshot metadata: %v; raw: %s", err, callText(res))
	}
	if meta.Tick != 6 || meta.Width != w || meta.Height != h {
		t.Fatalf("inspect_screenshot metadata wrong: %+v", meta)
	}
	if len(meta.Commands) != 1 || meta.Commands[0] != "Clear(color=Black)" {
		t.Fatalf("inspect_screenshot draw-list metadata wrong: %+v", meta.Commands)
	}
}

// TestInspectScreenshotPresentBoundaryRefusalNamesDrawListSubstitute proves the
// present-boundary refusal (a funpack binary built WITHOUT FUNPACK_LIVE) surfaces
// the MCP's OWN precise CategorySession envelope — naming the cause (the binary
// cannot cross the render/present boundary, pixel capture needs FUNPACK_LIVE) AND
// directing the caller to inspect_draw_list as the headless substitute — NOT a bare
// forward of the runtime string and NOT a transcode over an absent payload. The
// runtime's original text is preserved in Detail for fidelity. This mirrors the
// demux/session-bridge boundary pattern: the boundary that knows the operation owns
// the message rather than forwarding the upstream string.
func TestInspectScreenshotPresentBoundaryRefusalNamesDrawListSubstitute(t *testing.T) {
	// The exact text runtime/introspect.odin observe_screenshot returns on the
	// FUNPACK_LIVE present-boundary refusal — the MCP must NOT depend on it staying
	// precise, but it preserves it as Detail.
	const runtimeRefusal = "screenshot crosses the render/present boundary — requires a FUNPACK_LIVE build with a display (use draw_list for the sim-pure, headless draw-list dump)"
	fake := &inspectFakeCaller{handler: func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		return inspectErrResp(cmd, runtimeRefusal), nil
	}}
	cs, ctx := connectInspectTools(t, fake)

	res := callTool(t, cs, ctx, "inspect_screenshot", map[string]any{"session_id": "s1", "tick": 1})
	if !res.IsError {
		t.Fatal("inspect_screenshot did not flag IsError for a §28 present-boundary refusal")
	}
	if firstImageContent(res) != nil {
		t.Fatal("inspect_screenshot emitted an image content block on a refusal")
	}
	got := callText(res)
	// The envelope must be session-category, name the real cause (present boundary +
	// FUNPACK_LIVE), direct to the inspect_draw_list substitute, and carry the
	// runtime's original text as Detail — never a bare/opaque error.
	for _, want := range []string{
		`"category":"session"`,
		"render/present boundary",
		"FUNPACK_LIVE",
		"inspect_draw_list",
		`"detail":"runtime: ` + runtimeRefusal,
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("inspect_screenshot present-boundary envelope missing %q; got: %s", want, got)
		}
	}
	// It must NOT misread as a session-timeout / bad-artifact failure.
	for _, forbidden := range []string{"timed out", "context canceled", "bad artifact", "session was closed"} {
		if strings.Contains(got, forbidden) {
			t.Fatalf("inspect_screenshot present-boundary envelope leaked a misleading reading %q; got: %s", forbidden, got)
		}
	}
}

// TestInspectScreenshotInputRefusalIsForwardedUnreframed proves a caller-side
// argument refusal (tick out of range, missing tick, unknown branch) is forwarded
// as the runtime stated it — the caller fixes the ARGUMENT, so the MCP does NOT
// reframe it as the present-boundary case or point at inspect_draw_list (that would
// misdirect the caller away from the real fix).
func TestInspectScreenshotInputRefusalIsForwardedUnreframed(t *testing.T) {
	cases := []string{"tick out of range", "missing args.tick", "unknown branch — checkout an existing lineage"}
	for _, runtimeRefusal := range cases {
		t.Run(runtimeRefusal, func(t *testing.T) {
			fake := &inspectFakeCaller{handler: func(cmd string, _ json.RawMessage) (*contract.Response, error) {
				return inspectErrResp(cmd, runtimeRefusal), nil
			}}
			cs, ctx := connectInspectTools(t, fake)

			res := callTool(t, cs, ctx, "inspect_screenshot", map[string]any{"session_id": "s1", "tick": 999})
			if !res.IsError {
				t.Fatal("inspect_screenshot did not flag IsError for a §28 input refusal")
			}
			got := callText(res)
			if !strings.Contains(got, `"category":"session"`) {
				t.Fatalf("inspect_screenshot input refusal not session-category; got: %s", got)
			}
			if !strings.Contains(got, runtimeRefusal) {
				t.Fatalf("inspect_screenshot input refusal did not forward the runtime text %q; got: %s", runtimeRefusal, got)
			}
			// A caller-input refusal must NOT be reframed as the present boundary.
			for _, forbidden := range []string{"FUNPACK_LIVE", "inspect_draw_list", "render/present boundary"} {
				if strings.Contains(got, forbidden) {
					t.Fatalf("inspect_screenshot input refusal %q was wrongly reframed (leaked %q); got: %s", runtimeRefusal, forbidden, got)
				}
			}
		})
	}
}

// TestInspectScreenshotMalformedQOIIsInternalError proves a §28 ok:true response
// whose pixels are not valid QOI surfaces as an internal IsError (the runtime broke
// its own contract) rather than a panic or a silently-empty image.
func TestInspectScreenshotMalformedQOIIsInternalError(t *testing.T) {
	canned := screenshotResult{
		Tick: 1, Width: 2, Height: 1, Format: "qoi",
		Pixels: base64.StdEncoding.EncodeToString([]byte("not a qoi stream")),
	}
	fake := &inspectFakeCaller{handler: func(cmd string, _ json.RawMessage) (*contract.Response, error) {
		return inspectOkResp(t, cmd, canned), nil
	}}
	cs, ctx := connectInspectTools(t, fake)

	res := callTool(t, cs, ctx, "inspect_screenshot", map[string]any{"session_id": "s1", "tick": 1})
	if !res.IsError {
		t.Fatal("inspect_screenshot did not flag IsError for a malformed QOI payload")
	}
	if got := callText(res); !strings.Contains(got, `"category":"internal"`) {
		t.Fatalf("inspect_screenshot malformed-QOI envelope missing internal category; got: %s", got)
	}
}
