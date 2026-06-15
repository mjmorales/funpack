package server

import (
	"context"

	"github.com/mjmorales/funpack/mcp/internal/buildinfo"
	"github.com/mjmorales/funpack/mcp/internal/docs"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// HealthInput is empty: health is a no-argument liveness probe.
type HealthInput struct{}

// HealthOutput reports server identity so a connecting agent can confirm the
// funpack MCP is reachable and which build it is talking to. CorpusDrift surfaces
// a docs-corpus-vs-compiler version skew on the very first probe, so a stale
// corpus is visible before the agent ever trusts a docs_search answer.
type HealthOutput struct {
	Status      string      `json:"status" jsonschema:"liveness status, ok when the server responds"`
	Server      string      `json:"server" jsonschema:"server name"`
	Version     string      `json:"version" jsonschema:"server build version"`
	CorpusDrift CorpusDrift `json:"corpus_drift" jsonschema:"docs-corpus-vs-resolved-compiler funpack version skew; drift=true means the docs describe an older toolchain than the one that compiles"`
}

// registerHealth wires the health tool: a no-argument liveness probe that also
// proves the server registers a typed tool and answers tools/call end to end, and
// reports any docs-corpus-vs-compiler version drift. The manifest loads once at
// registration (the same fail-fast convention docs_get/docs_search follow) and the
// compiler is resolved once, so the probe is cheap and the drift verdict is stable.
func registerHealth(srv *mcp.Server, logger zerolog.Logger) {
	manifest, err := docs.LoadManifest()
	if err != nil {
		panic("health: load corpus manifest: " + err.Error())
	}
	drift := detectCorpusDrift(manifest)
	if drift.Drift {
		logger.Warn().
			Str("corpus_funpack", drift.CorpusVersion).
			Str("compiler_funpack", drift.CompilerVersion).
			Msg("docs corpus version lags the resolved compiler — health reports drift")
	}

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "health",
		Description: "Report funpack MCP server liveness, build version, and any docs-corpus-vs-compiler version drift.",
	}, func(_ context.Context, _ *mcp.CallToolRequest, _ HealthInput) (*mcp.CallToolResult, HealthOutput, error) {
		logger.Debug().Msg("health probe")
		return nil, HealthOutput{
			Status:      "ok",
			Server:      Name,
			Version:     buildinfo.Version,
			CorpusDrift: drift,
		}, nil
	})
}
