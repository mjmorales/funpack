package server

import (
	"context"

	"github.com/mjmorales/funpack/mcp/internal/docs"
	"github.com/mjmorales/funpack/mcp/internal/docs/search"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// docsSearchDefaultLimit is the hit cap applied when a caller omits Limit (or
// passes <= 0): a screenful of ranked hits, enough to choose from without
// flooding the model's context.
const docsSearchDefaultLimit = 10

// docsSearchMaxLimit caps an explicit Limit so a single call cannot drain the
// whole ranked candidate pool into one response.
const docsSearchMaxLimit = 50

// DocsSearchInput is a query plus an optional hit cap. The query's SHAPE
// (identifier vs natural language) steers the ranker; see the search package.
type DocsSearchInput struct {
	Query string `json:"query" jsonschema:"search query: an engine symbol/identifier (e.g. world.resolve, @stub) for a declaration, or natural language (e.g. how does determinism work) for a concept"`
	Limit int    `json:"limit,omitempty" jsonschema:"maximum hits to return; omit or <= 0 for the default (10), capped at 50"`
}

// Hit is one ranked search result, source-tagged so the caller knows whether it
// resolved a named symbol or a prose passage. Anchor re-resolves the hit through
// docs_get; Score is a relative rank key comparable only within one response.
type Hit struct {
	Anchor  string  `json:"anchor" jsonschema:"stable corpus anchor; pass to docs_get to fetch the full section"`
	Title   string  `json:"title" jsonschema:"human-readable heading or symbol name"`
	Kind    string  `json:"kind" jsonschema:"corpus source category: spec, engine, or plugin"`
	Score   float64 `json:"score" jsonschema:"blended relative rank key; higher ranks earlier, comparable only within this response"`
	Snippet string  `json:"snippet" jsonschema:"short display window: matching prose for a passage, or the one-line signature for a symbol"`
	Source  string  `json:"source" jsonschema:"which ranker produced the hit: symbol or passage"`
}

// DocsSearchOutput is the ranked hit list plus the corpus version it ranked
// against, so a caller can tell which build's docs answered and detect a stale
// pin against a known spec/funpack version.
type DocsSearchOutput struct {
	Hits          []Hit  `json:"hits" jsonschema:"ranked search hits, best first; empty when nothing matched"`
	CorpusVersion string `json:"corpus_version" jsonschema:"version stamp of the corpus that answered, derived from the manifest (spec ref + funpack version)"`
}

// registerDocsSearch wires the docs_search tool: query in, ranked hits out. The
// corpus is embedded and immutable per build, so the search engine and the
// corpus-version stamp are built ONCE at registration and every call reuses the
// same in-memory index — Search is pure and safe to share across concurrent
// invocations. A corpus or manifest load failure is fatal at registration (the
// binary cannot serve docs without its own embedded corpus), surfaced as a panic
// the server bootstrap owns — the same convention docs_get follows.
func registerDocsSearch(srv *mcp.Server, logger zerolog.Logger) {
	corpus, err := docs.Load()
	if err != nil {
		panic("docs_search: load embedded corpus: " + err.Error())
	}
	manifest, err := docs.LoadManifest()
	if err != nil {
		panic("docs_search: load corpus manifest: " + err.Error())
	}

	engine := search.New(corpus)
	corpusVersion := corpusVersion(manifest)

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "docs_search",
		Description: "Search the funpack documentation corpus and return ranked hits. A symbol-shaped query resolves declarations first; natural language resolves explanatory passages first. Each hit's anchor feeds docs_get for the full section.",
	}, func(_ context.Context, _ *mcp.CallToolRequest, in DocsSearchInput) (*mcp.CallToolResult, DocsSearchOutput, error) {
		if in.Query == "" {
			logger.Debug().Msg("docs_search empty query")
			res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategoryInvalidInput, "query must not be empty"))
			return res, DocsSearchOutput{}, protoErr
		}

		limit := in.Limit
		if limit <= 0 {
			limit = docsSearchDefaultLimit
		}
		if limit > docsSearchMaxLimit {
			limit = docsSearchMaxLimit
		}

		results := engine.Search(in.Query, limit)
		hits := make([]Hit, 0, len(results))
		for _, r := range results {
			hits = append(hits, Hit{
				Anchor:  r.Anchor,
				Title:   r.Title,
				Kind:    string(r.Kind),
				Score:   r.Score,
				Snippet: r.Snippet,
				Source:  string(r.Source),
			})
		}
		logger.Debug().Str("query", in.Query).Int("limit", limit).Int("hits", len(hits)).Msg("docs_search")
		return nil, DocsSearchOutput{Hits: hits, CorpusVersion: corpusVersion}, nil
	})
}

// corpusVersion stamps a single human-readable version string from the manifest:
// the spec ref the prose/engine sources were read at, joined with the funpack
// version the plugin sources came from. Both halves are content-derived (no
// timestamp, no path), so the stamp is stable across a regen of unchanged sources.
func corpusVersion(m *docs.Manifest) string {
	return "spec " + m.SpecRef + " / " + m.FunpackVersion
}
