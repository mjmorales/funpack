package server

import (
	"context"

	"github.com/mjmorales/funpack/mcp/internal/buildinfo"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// HealthInput is empty: health is a no-argument liveness probe.
type HealthInput struct{}

// HealthOutput reports server identity so a connecting agent can confirm the
// funpack MCP is reachable and which build it is talking to.
type HealthOutput struct {
	Status  string `json:"status" jsonschema:"liveness status, ok when the server responds"`
	Server  string `json:"server" jsonschema:"server name"`
	Version string `json:"version" jsonschema:"server build version"`
}

// registerHealth wires the health tool: a no-argument liveness probe that also
// proves the server registers a typed tool and answers tools/call end to end.
func registerHealth(srv *mcp.Server, logger zerolog.Logger) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "health",
		Description: "Report funpack MCP server liveness and build version.",
	}, func(_ context.Context, _ *mcp.CallToolRequest, _ HealthInput) (*mcp.CallToolResult, HealthOutput, error) {
		logger.Debug().Msg("health probe")
		return nil, HealthOutput{
			Status:  "ok",
			Server:  Name,
			Version: buildinfo.Version,
		}, nil
	})
}
