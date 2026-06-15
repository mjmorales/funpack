package server

import (
	"github.com/mjmorales/funpack/mcp/internal/buildinfo"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// Name is the MCP server identity reported to clients during initialization.
const Name = "funpack-mcp"

// New constructs the funpack MCP server with every tool registered. The returned
// server is transport-agnostic: serve binds it to stdio, tests bind it to an
// in-memory transport. As tools land (one-shot verbs, §28 session tools, docs
// search), register them here.
func New(logger zerolog.Logger) *mcp.Server {
	srv := mcp.NewServer(&mcp.Implementation{
		Name:    Name,
		Version: buildinfo.Version,
	}, nil)

	registerHealth(srv, logger)
	registerDocsGet(srv, logger)
	registerDocsSearch(srv, logger)

	return srv
}
