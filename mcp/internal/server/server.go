package server

import (
	"github.com/mjmorales/funpack/mcp/internal/buildinfo"
	"github.com/mjmorales/funpack/mcp/internal/session"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// Name is the MCP server identity reported to clients during initialization.
const Name = "funpack-mcp"

// DefaultMaxSessions caps the number of concurrently live supervised attach
// sessions the server admits (spec §28's bounded session lifetime). It is the
// admission half of the lifecycle; the Reaper serve drives is the time half.
const DefaultMaxSessions = 8

// New constructs the funpack MCP server with every tool registered, and returns
// the shared session Registry the serve driver wires a Reaper + shutdown CloseAll
// against. The returned server is transport-agnostic: serve binds it to stdio,
// tests bind it to an in-memory transport. As tools land (one-shot verbs, §28
// session tools, docs search), register them here.
//
// One session Registry is shared across the session-scoped surface: session_*
// lifecycle tools register against it here, and the Reaper + per-session §28 tools
// key on the same instance. The Registry is returned (not kept private) so the
// driver owns the two lifecycle halves the server itself cannot run — starting the
// Reaper goroutine and the shutdown CloseAll sweep — without re-deriving the
// instance. It is capped at DefaultMaxSessions; tests that ignore the registry
// discard it.
func New(logger zerolog.Logger) (*mcp.Server, *session.Registry) {
	srv := mcp.NewServer(&mcp.Implementation{
		Name:    Name,
		Version: buildinfo.Version,
	}, nil)

	registerHealth(srv, logger)
	registerDocsGet(srv, logger)
	registerDocsSearch(srv, logger)
	registerBuildTools(srv, logger)
	registerTestTool(srv, logger)
	registerWardenTools(srv, logger)

	reg := session.NewRegistryWithMax(DefaultMaxSessions)
	registerSessionTools(srv, logger, reg)
	registerTimeTools(srv, logger, reg)
	registerControlTools(srv, logger, reg)
	registerSelfHealTools(srv, logger, reg)

	return srv, reg
}
