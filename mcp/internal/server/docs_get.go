package server

import (
	"context"

	"github.com/mjmorales/funpack/mcp/internal/docs"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// DocsGetInput selects one documentation section by its stable anchor — the same
// anchor downstream indices and search results key on.
type DocsGetInput struct {
	Anchor string `json:"anchor" jsonschema:"stable corpus anchor of the section to fetch (e.g. an engine/<module>#<decl> or <file>#<heading-slug> anchor)"`
}

// DocsGetOutput is the full section the anchor resolved to: enough to render the
// passage without a second lookup.
type DocsGetOutput struct {
	Anchor string `json:"anchor" jsonschema:"the resolved section anchor, echoing the request"`
	Title  string `json:"title" jsonschema:"human-readable heading or declaration name"`
	Kind   string `json:"kind" jsonschema:"source category: spec, engine, or plugin"`
	Text   string `json:"text" jsonschema:"full section body text"`
}

// registerDocsGet wires the docs_get tool: anchor in, full section out. The
// corpus is embedded and immutable per build, so it loads once at registration
// and every call reads the same in-memory index — no per-call filesystem work.
// A load failure is fatal at registration (the binary cannot serve docs without
// its own embedded corpus), surfaced as a panic the server bootstrap owns.
func registerDocsGet(srv *mcp.Server, logger zerolog.Logger) {
	corpus, err := docs.Load()
	if err != nil {
		panic("docs_get: load embedded corpus: " + err.Error())
	}

	byAnchor := make(map[string]docs.Section, len(corpus.Sections))
	for _, s := range corpus.Sections {
		byAnchor[s.Anchor] = s
	}

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "docs_get",
		Description: "Fetch the full text of one funpack documentation section by its stable anchor.",
	}, func(_ context.Context, _ *mcp.CallToolRequest, in DocsGetInput) (*mcp.CallToolResult, DocsGetOutput, error) {
		sec, ok := byAnchor[in.Anchor]
		if !ok {
			logger.Debug().Str("anchor", in.Anchor).Msg("docs_get miss")
			res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategoryInvalidInput, "unknown anchor: "+in.Anchor))
			return res, DocsGetOutput{}, protoErr
		}
		logger.Debug().Str("anchor", in.Anchor).Msg("docs_get hit")
		return nil, DocsGetOutput{
			Anchor: sec.Anchor,
			Title:  sec.Title,
			Kind:   string(sec.Kind),
			Text:   sec.Text,
		}, nil
	})
}
