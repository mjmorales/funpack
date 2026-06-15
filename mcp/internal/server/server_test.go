package server

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/mjmorales/funpack/mcp/internal/docs"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// connectLoopback wires a client to a fresh server over the in-memory transport
// pair — the same JSON-RPC path stdio drives, minus the OS pipe — and returns the
// connected client session. Both sessions close when the test ends.
func connectLoopback(t *testing.T) (*mcp.ClientSession, context.Context) {
	t.Helper()
	ctx := context.Background()

	srv, _ := New(zerolog.Nop())
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

// callText concatenates every TextContent block of a tool result into one string.
func callText(res *mcp.CallToolResult) string {
	var text strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			text.WriteString(tc.Text)
		}
	}
	return text.String()
}

// TestDocsGetReturnsSectionText proves docs_get resolves a real anchor to its
// full section text over the wire. The anchor is chosen from the embedded corpus
// the server itself loads, so the test tracks the corpus rather than pinning a
// literal anchor that a regen could invalidate.
func TestDocsGetReturnsSectionText(t *testing.T) {
	corpus, err := docs.Load()
	if err != nil {
		t.Fatalf("load corpus: %v", err)
	}
	if len(corpus.Sections) == 0 {
		t.Fatal("corpus has no sections to test against")
	}
	want := corpus.Sections[0]
	if want.Text == "" {
		t.Skip("first corpus section has empty text; cannot assert round-trip")
	}

	session, ctx := connectLoopback(t)

	res, err := session.CallTool(ctx, &mcp.CallToolParams{
		Name:      "docs_get",
		Arguments: map[string]any{"anchor": want.Anchor},
	})
	if err != nil {
		t.Fatalf("call docs_get: %v", err)
	}
	if res.IsError {
		t.Fatalf("docs_get reported a tool error for a known anchor: %s", callText(res))
	}

	// The section text travels as a JSON-encoded string field, so newlines and
	// quotes arrive escaped; assert against the marshaled form, not the raw text.
	encoded, err := json.Marshal(want.Text)
	if err != nil {
		t.Fatalf("marshal want text: %v", err)
	}
	got := callText(res)
	if !strings.Contains(got, string(encoded)) {
		t.Fatalf("docs_get response missing section text for anchor %q; got: %s", want.Anchor, got)
	}
}

// TestDocsGetUnknownAnchorIsStructuredError proves an unknown anchor surfaces a
// structured IsError envelope (invalid_input category) the model can read and
// self-correct from, rather than a protocol-level error.
func TestDocsGetUnknownAnchorIsStructuredError(t *testing.T) {
	session, ctx := connectLoopback(t)

	res, err := session.CallTool(ctx, &mcp.CallToolParams{
		Name:      "docs_get",
		Arguments: map[string]any{"anchor": "no/such#anchor"},
	})
	if err != nil {
		t.Fatalf("call docs_get: %v", err)
	}
	if !res.IsError {
		t.Fatalf("docs_get did not flag IsError for an unknown anchor")
	}

	got := callText(res)
	for _, want := range []string{`"category":"invalid_input"`, "unknown anchor: no/such#anchor"} {
		if !strings.Contains(got, want) {
			t.Fatalf("docs_get error envelope missing %q; got: %s", want, got)
		}
	}
}

// docsSearchResult is the slice of DocsSearchOutput the tests assert against,
// decoded from the structured result of a docs_search call.
type docsSearchResult struct {
	Hits []struct {
		Anchor  string `json:"anchor"`
		Title   string `json:"title"`
		Kind    string `json:"kind"`
		Source  string `json:"source"`
		Snippet string `json:"snippet"`
	} `json:"hits"`
	CorpusVersion string `json:"corpus_version"`
}

// decodeSearch unmarshals the docs_search structured output from a tool result's
// TextContent. The handler returns a typed Output, which the SDK marshals into
// the result's text payload as the structured JSON object.
func decodeSearch(t *testing.T, res *mcp.CallToolResult) docsSearchResult {
	t.Helper()
	var out docsSearchResult
	if err := json.Unmarshal([]byte(callText(res)), &out); err != nil {
		t.Fatalf("decode docs_search output: %v; raw: %s", err, callText(res))
	}
	return out
}

// callSearch issues a docs_search tools/call over the wire and returns the raw
// result; arguments mirror the DocsSearchInput shape.
func callSearch(t *testing.T, session *mcp.ClientSession, ctx context.Context, args map[string]any) *mcp.CallToolResult {
	t.Helper()
	res, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "docs_search", Arguments: args})
	if err != nil {
		t.Fatalf("call docs_search: %v", err)
	}
	return res
}

// TestDocsSearchConceptualQueryRanksHits proves a natural-language query returns
// ranked hits — each with a non-empty re-resolvable anchor — and a corpus version
// stamp, the two guarantees a caller needs to act on a result (fetch via docs_get)
// and know which build answered.
func TestDocsSearchConceptualQueryRanksHits(t *testing.T) {
	session, ctx := connectLoopback(t)

	res := callSearch(t, session, ctx, map[string]any{"query": "how does determinism work"})
	if res.IsError {
		t.Fatalf("docs_search reported a tool error for a conceptual query: %s", callText(res))
	}

	out := decodeSearch(t, res)
	if len(out.Hits) == 0 {
		t.Fatal("docs_search returned no hits for a conceptual query")
	}
	if out.CorpusVersion == "" {
		t.Fatal("docs_search returned an empty corpus version")
	}
	for i, h := range out.Hits {
		if h.Anchor == "" {
			t.Fatalf("docs_search hit %d has an empty anchor", i)
		}
	}
}

// TestDocsSearchSymbolQueryReturnsSymbolHit proves a symbol-shaped query (a real
// engine declaration name drawn from the embedded corpus) surfaces that symbol as
// a source=symbol hit. The query is derived from the corpus the server loads, so
// the test tracks the corpus rather than pinning a literal symbol a regen could
// invalidate.
func TestDocsSearchSymbolQueryReturnsSymbolHit(t *testing.T) {
	corpus, err := docs.Load()
	if err != nil {
		t.Fatalf("load corpus: %v", err)
	}
	var engineSec docs.Section
	for _, s := range corpus.Sections {
		if s.Kind == docs.KindEngine && s.Title != "" {
			engineSec = s
			break
		}
	}
	if engineSec.Title == "" {
		t.Skip("corpus has no engine section to derive a symbol query from")
	}

	session, ctx := connectLoopback(t)

	res := callSearch(t, session, ctx, map[string]any{"query": engineSec.Title})
	if res.IsError {
		t.Fatalf("docs_search reported a tool error for a symbol query: %s", callText(res))
	}

	out := decodeSearch(t, res)
	if len(out.Hits) == 0 {
		t.Fatalf("docs_search returned no hits for engine symbol %q", engineSec.Title)
	}
	var sawSymbol bool
	for _, h := range out.Hits {
		if h.Source == "symbol" && h.Anchor == engineSec.Anchor {
			sawSymbol = true
			break
		}
	}
	if !sawSymbol {
		t.Fatalf("docs_search did not return a symbol hit for engine declaration %q (anchor %q); hits: %+v", engineSec.Title, engineSec.Anchor, out.Hits)
	}
}

// TestDocsSearchEmptyQueryIsStructuredError proves an empty query surfaces the
// structured invalid_input IsError envelope the model can read and self-correct
// from, rather than a protocol-level error.
func TestDocsSearchEmptyQueryIsStructuredError(t *testing.T) {
	session, ctx := connectLoopback(t)

	res := callSearch(t, session, ctx, map[string]any{"query": ""})
	if !res.IsError {
		t.Fatal("docs_search did not flag IsError for an empty query")
	}
	got := callText(res)
	for _, want := range []string{`"category":"invalid_input"`, "query must not be empty"} {
		if !strings.Contains(got, want) {
			t.Fatalf("docs_search error envelope missing %q; got: %s", want, got)
		}
	}
}

// TestDocsSearchLimitRespected proves an explicit Limit caps the returned hit
// count. The query is conceptual to draw from the large passage pool, so a small
// limit is a real truncation rather than the natural result count.
func TestDocsSearchLimitRespected(t *testing.T) {
	session, ctx := connectLoopback(t)

	const limit = 3
	res := callSearch(t, session, ctx, map[string]any{"query": "entity world physics determinism", "limit": limit})
	if res.IsError {
		t.Fatalf("docs_search reported a tool error: %s", callText(res))
	}
	out := decodeSearch(t, res)
	if len(out.Hits) > limit {
		t.Fatalf("docs_search returned %d hits, exceeding limit %d", len(out.Hits), limit)
	}
}
