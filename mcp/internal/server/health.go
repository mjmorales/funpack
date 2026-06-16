package server

import (
	"context"

	"github.com/mjmorales/funpack/mcp/internal/buildinfo"
	"github.com/mjmorales/funpack/mcp/internal/docs"
	"github.com/mjmorales/funpack/mcp/internal/funpack"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// HealthInput is empty: health is a no-argument liveness probe.
type HealthInput struct{}

// HealthOutput reports server identity so a connecting agent can confirm the
// funpack MCP is reachable and which build it is talking to. CorpusDrift surfaces
// a docs-corpus-vs-compiler version skew, and FunpackCompat surfaces a
// compiler-schema-vs-this-MCP-build skew — both on the very first probe, so a
// stale corpus or a version-skewed compiler is visible before the agent trusts a
// tool result. The compiler-schema gate is advisory now (serve no longer refuses
// startup on skew), so this is where the skew is reported.
type HealthOutput struct {
	Status        string                `json:"status" jsonschema:"liveness status, ok when the server responds"`
	Server        string                `json:"server" jsonschema:"server name"`
	Version       string                `json:"version" jsonschema:"server build version"`
	CorpusDrift   CorpusDrift           `json:"corpus_drift" jsonschema:"docs-corpus-vs-resolved-compiler funpack version skew; drift=true means the docs describe an older toolchain than the one that compiles"`
	FunpackCompat *funpack.SchemaCompat `json:"funpack_compat,omitempty" jsonschema:"resolved-compiler schema vs this MCP build's supported window; compatible=false flags skew (advisory, not blocking); null when no funpack resolved"`
}

// resolveFunpackBinary is the funpack-resolution seam health reads to compute the
// schema-compat surface, a package var so a test can drive a skewed/absent compiler
// without execing a real funpack.
var resolveFunpackBinary = funpack.Resolve

// registerHealth wires the health tool: a no-argument liveness probe that also
// proves the server registers a typed tool and answers tools/call end to end, and
// reports any docs-corpus-vs-compiler version drift plus the resolved-compiler
// schema compatibility. The manifest loads once at registration (the same fail-fast
// convention docs_get/docs_search follow) and the compiler is resolved once, so the
// probe is cheap and both verdicts are stable.
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

	// Resolve the compiler once for the advisory schema-compat surface. A miss is
	// fine — funpack_compat is simply omitted (null) and the docs tools still work.
	var compat *funpack.SchemaCompat
	if bin, rerr := resolveFunpackBinary(); rerr == nil {
		c := funpack.CheckSchemaCompat(bin)
		compat = &c
		if !c.Compatible {
			logger.Warn().
				Str("funpack", bin.Path).
				Str("funpack_version", bin.Version.Version).
				Msg("resolved compiler schema differs from this MCP build's supported window — health reports funpack_compat skew (advisory)")
		}
	}

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "health",
		Description: "Report funpack MCP server liveness, build version, docs-corpus-vs-compiler drift, and resolved-compiler schema compatibility.",
	}, func(_ context.Context, _ *mcp.CallToolRequest, _ HealthInput) (*mcp.CallToolResult, HealthOutput, error) {
		logger.Debug().Msg("health probe")
		return nil, HealthOutput{
			Status:        "ok",
			Server:        Name,
			Version:       buildinfo.Version,
			CorpusDrift:   drift,
			FunpackCompat: compat,
		}, nil
	})
}
