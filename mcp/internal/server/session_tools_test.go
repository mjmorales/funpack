package server

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/mjmorales/funpack/mcp/internal/funpack"
	"github.com/mjmorales/funpack/mcp/internal/session"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// connectSessionTools wires a BARE server (no New, so server.go is untouched)
// carrying ONLY the session tools, registered against a fresh Registry with the
// supervised-attach opener INJECTED so session_start drives without a live funpack
// runtime. It returns the connected client, the registry the test inspects, and
// the context. Both sessions and every fake child group close when the test ends.
func connectSessionTools(t *testing.T, open sessionOpener) (*mcp.ClientSession, *session.Registry, context.Context) {
	t.Helper()
	ctx := context.Background()

	reg := session.NewRegistry()
	t.Cleanup(reg.CloseAll)

	srv := mcp.NewServer(&mcp.Implementation{Name: "funpack-mcp-test", Version: "v0.0.0"}, nil)
	registerSessionToolsWith(srv, zerolog.Nop(), reg, stubResolver, open)

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

	return clientSession, reg, ctx
}

// stubResolver is the fake sessionResolver: it returns a stub Binary without
// shelling out to `funpack version --json`, so session_start drives without a
// funpack on PATH.
func stubResolver() (funpack.Binary, error) {
	return funpack.Binary{Path: "/bin/sh"}, nil
}

// fakeOpener returns a sessionOpener that opens a fake session (no live runtime)
// over the requested artifact, so session_start exercises the full registry path.
func fakeOpener() sessionOpener {
	return func(ctx context.Context, _ funpack.Binary, artifact string, _ session.Config) (*session.Session, error) {
		return session.OpenFake(ctx, artifact, zerolog.Nop())
	}
}

// callTool issues a tools/call over the wire and returns the raw result.
func callTool(t *testing.T, cs *mcp.ClientSession, ctx context.Context, name string, args map[string]any) *mcp.CallToolResult {
	t.Helper()
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("call %s: %v", name, err)
	}
	return res
}

// sessionStartResult is the decoded session_start structured output.
type sessionStartResult struct {
	SessionID         string `json:"session_id"`
	NegotiatedVersion int    `json:"negotiated_version"`
}

// sessionListResult is the decoded session_list structured output.
type sessionListResult struct {
	Sessions []struct {
		ID                string `json:"id"`
		NegotiatedVersion int    `json:"negotiated_version"`
		Artifact          string `json:"artifact"`
		CreatedAt         string `json:"created_at"`
	} `json:"sessions"`
}

// TestSessionStartRegistersAndListShows proves session_start opens via the
// injected fake opener, returns an id + negotiated version, registers the session
// in the shared Registry, and session_list then surfaces it with non-secret info.
func TestSessionStartRegistersAndListShows(t *testing.T) {
	cs, reg, ctx := connectSessionTools(t, fakeOpener())

	res := callTool(t, cs, ctx, "session_start", map[string]any{"artifact": "demo.fp"})
	if res.IsError {
		t.Fatalf("session_start reported a tool error: %s", callText(res))
	}
	var start sessionStartResult
	if err := json.Unmarshal([]byte(callText(res)), &start); err != nil {
		t.Fatalf("decode session_start output: %v; raw: %s", err, callText(res))
	}
	if start.SessionID == "" {
		t.Fatal("session_start returned an empty session id")
	}
	if start.NegotiatedVersion != contract.ProtocolVersion {
		t.Fatalf("session_start negotiated version: got %d, want %d", start.NegotiatedVersion, contract.ProtocolVersion)
	}

	// It is registered in the shared registry the reaper also keys on.
	if _, ok := reg.Get(start.SessionID); !ok {
		t.Fatalf("session_start did not register %q in the shared registry", start.SessionID)
	}

	// session_list surfaces it with non-secret info.
	listRes := callTool(t, cs, ctx, "session_list", map[string]any{})
	if listRes.IsError {
		t.Fatalf("session_list reported a tool error: %s", callText(listRes))
	}
	var list sessionListResult
	if err := json.Unmarshal([]byte(callText(listRes)), &list); err != nil {
		t.Fatalf("decode session_list output: %v; raw: %s", err, callText(listRes))
	}
	if len(list.Sessions) != 1 {
		t.Fatalf("session_list returned %d sessions, want 1", len(list.Sessions))
	}
	entry := list.Sessions[0]
	if entry.ID != start.SessionID || entry.Artifact != "demo.fp" || entry.NegotiatedVersion != contract.ProtocolVersion {
		t.Fatalf("session_list entry wrong: %+v", entry)
	}
	// No secret leaks: the raw list payload must carry neither a token nor a port field.
	raw := callText(listRes)
	for _, secret := range []string{"token", "\"port\""} {
		if strings.Contains(raw, secret) {
			t.Fatalf("session_list payload leaked a secret field %q: %s", secret, raw)
		}
	}
}

// TestSessionEndClosesAndDeregisters proves session_end on a live id closes the
// session, deregisters it from the shared registry, and session_list no longer
// shows it.
func TestSessionEndClosesAndDeregisters(t *testing.T) {
	cs, reg, ctx := connectSessionTools(t, fakeOpener())

	res := callTool(t, cs, ctx, "session_start", map[string]any{"artifact": "demo.fp"})
	if res.IsError {
		t.Fatalf("session_start error: %s", callText(res))
	}
	var start sessionStartResult
	if err := json.Unmarshal([]byte(callText(res)), &start); err != nil {
		t.Fatalf("decode session_start: %v", err)
	}

	endRes := callTool(t, cs, ctx, "session_end", map[string]any{"session_id": start.SessionID})
	if endRes.IsError {
		t.Fatalf("session_end reported a tool error: %s", callText(endRes))
	}
	if _, ok := reg.Get(start.SessionID); ok {
		t.Fatal("session_end did not deregister the session")
	}

	listRes := callTool(t, cs, ctx, "session_list", map[string]any{})
	var list sessionListResult
	if err := json.Unmarshal([]byte(callText(listRes)), &list); err != nil {
		t.Fatalf("decode session_list: %v", err)
	}
	if len(list.Sessions) != 0 {
		t.Fatalf("session_list still shows %d sessions after session_end", len(list.Sessions))
	}
}

// TestSessionEndUnknownIDIsStructuredError proves session_end on an id that was
// never registered surfaces the structured invalid_input IsError envelope the
// model can read and self-correct from, rather than a protocol-level error.
func TestSessionEndUnknownIDIsStructuredError(t *testing.T) {
	cs, _, ctx := connectSessionTools(t, fakeOpener())

	res := callTool(t, cs, ctx, "session_end", map[string]any{"session_id": "no-such-session"})
	if !res.IsError {
		t.Fatal("session_end did not flag IsError for an unknown id")
	}
	got := callText(res)
	for _, want := range []string{`"category":"invalid_input"`, "unknown session id: no-such-session"} {
		if !strings.Contains(got, want) {
			t.Fatalf("session_end error envelope missing %q; got: %s", want, got)
		}
	}
}

// TestSessionStartEmptyArtifactIsStructuredError proves an empty artifact is
// rejected as a structured invalid_input tool error BEFORE any resolve/open, so
// the model corrects the argument rather than seeing a resolver failure.
func TestSessionStartEmptyArtifactIsStructuredError(t *testing.T) {
	// A panicking opener proves the empty-artifact guard short-circuits before open.
	panicOpener := func(context.Context, funpack.Binary, string, session.Config) (*session.Session, error) {
		t.Fatal("opener must not be called for an empty artifact")
		return nil, nil
	}
	cs, _, ctx := connectSessionTools(t, panicOpener)

	res := callTool(t, cs, ctx, "session_start", map[string]any{"artifact": ""})
	if !res.IsError {
		t.Fatal("session_start did not flag IsError for an empty artifact")
	}
	got := callText(res)
	for _, want := range []string{`"category":"invalid_input"`, "artifact must not be empty"} {
		if !strings.Contains(got, want) {
			t.Fatalf("session_start error envelope missing %q; got: %s", want, got)
		}
	}
}

// TestSessionStartResolveFailureIsStructuredError proves a funpack-resolve failure
// surfaces as a structured resolver IsError envelope the model can read, and that
// the opener is never reached when resolution fails (no orphaned session).
func TestSessionStartResolveFailureIsStructuredError(t *testing.T) {
	reg := session.NewRegistry()
	t.Cleanup(reg.CloseAll)

	srv := mcp.NewServer(&mcp.Implementation{Name: "funpack-mcp-test", Version: "v0.0.0"}, nil)
	failResolver := func() (funpack.Binary, error) { return funpack.Binary{}, funpack.ErrNotFound }
	panicOpener := func(context.Context, funpack.Binary, string, session.Config) (*session.Session, error) {
		t.Fatal("opener must not be called when resolution fails")
		return nil, nil
	}
	registerSessionToolsWith(srv, zerolog.Nop(), reg, failResolver, panicOpener)

	serverT, clientT := mcp.NewInMemoryTransports()
	ctx := context.Background()
	serverSession, err := srv.Connect(ctx, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	t.Cleanup(func() { _ = serverSession.Close() })
	client := mcp.NewClient(&mcp.Implementation{Name: "c", Version: "v0"}, nil)
	cs, err := client.Connect(ctx, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { _ = cs.Close() })

	res := callTool(t, cs, ctx, "session_start", map[string]any{"artifact": "demo.fp"})
	if !res.IsError {
		t.Fatal("session_start did not flag IsError on a resolve failure")
	}
	if got := callText(res); !strings.Contains(got, `"category":"resolver"`) {
		t.Fatalf("session_start resolve-failure envelope missing resolver category; got: %s", got)
	}
	if len(reg.List()) != 0 {
		t.Fatal("a failed resolve registered a session")
	}
}

// TestSessionToolsAdvertised confirms all three session tools appear in
// tools/list, so an agent can discover them before calling.
func TestSessionToolsAdvertised(t *testing.T) {
	cs, _, ctx := connectSessionTools(t, fakeOpener())

	res, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	want := map[string]bool{"session_start": false, "session_end": false, "session_list": false}
	for _, tool := range res.Tools {
		if _, ok := want[tool.Name]; ok {
			want[tool.Name] = true
		}
	}
	for name, seen := range want {
		if !seen {
			t.Fatalf("session tool %q not advertised in tools/list", name)
		}
	}
}
