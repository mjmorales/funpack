package server

import (
	"context"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// connectLoopback wires a client to a fresh server over the in-memory transport
// pair — the same JSON-RPC path stdio drives, minus the OS pipe — and returns the
// connected client session. Both sessions close when the test ends.
func connectLoopback(t *testing.T) (*mcp.ClientSession, context.Context) {
	t.Helper()
	ctx := context.Background()

	srv := New(zerolog.Nop())
	serverT, clientT := mcp.NewInMemoryTransports()

	serverSession, err := srv.Connect(ctx, serverT, nil)
	if err != nil {
		t.Fatalf("server connect: %v", err)
	}
	t.Cleanup(func() { _ = serverSession.Close() })

	client := mcp.NewClient(&mcp.Implementation{Name: "funpack-mcp-test", Version: "v0.0.0"}, nil)
	clientSession, err := client.Connect(ctx, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { _ = clientSession.Close() })

	return clientSession, ctx
}

// TestHealthToolOverRPC proves the health tool registers and answers a real
// tools/call — the scaffold's "server registers + responds" guarantee exercised
// over the wire, not by calling the handler directly.
func TestHealthToolOverRPC(t *testing.T) {
	session, ctx := connectLoopback(t)

	res, err := session.CallTool(ctx, &mcp.CallToolParams{
		Name:      "health",
		Arguments: map[string]any{},
	})
	if err != nil {
		t.Fatalf("call health: %v", err)
	}
	if res.IsError {
		t.Fatalf("health reported a tool error: %+v", res.Content)
	}

	var text strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			text.WriteString(tc.Text)
		}
	}
	got := text.String()
	for _, want := range []string{`"status":"ok"`, `"server":"funpack-mcp"`} {
		if !strings.Contains(got, want) {
			t.Fatalf("health response missing %q; got: %s", want, got)
		}
	}
}

// TestListToolsAdvertisesHealth confirms health appears in tools/list, so an
// agent can discover it before calling.
func TestListToolsAdvertisesHealth(t *testing.T) {
	session, ctx := connectLoopback(t)

	res, err := session.ListTools(ctx, nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	for _, tool := range res.Tools {
		if tool.Name == "health" {
			return
		}
	}
	t.Fatalf("health tool not advertised in tools/list")
}
