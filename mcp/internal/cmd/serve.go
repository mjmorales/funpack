package cmd

import (
	"errors"
	"io"
	"os/signal"
	"syscall"
	"time"

	"github.com/mjmorales/funpack/mcp/internal/server"
	"github.com/mjmorales/funpack/mcp/internal/session"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/spf13/cobra"
)

// Session lifecycle bounds (spec §28): a session idle past idleTTL is reaped, and
// the reaper sweeps on reaperTick. There is no MaxLifetime ceiling by default — a
// session actively driven by Call stays alive — but it is reaped the moment it
// goes idle long enough, so a forgotten attach never leaks past idleTTL.
const (
	idleTTL    = 10 * time.Minute
	reaperTick = 30 * time.Second
)

// newServeCommand runs the MCP server over stdio until the client disconnects or
// the process receives SIGINT/SIGTERM. Clients (e.g. .mcp.json) invoke
// `funpack-mcp serve`.
func newServeCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "serve",
		Short: "Run the funpack MCP server over stdio",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			logger := loggerFrom(cmd.Context())

			ctx, stop := signal.NotifyContext(cmd.Context(), syscall.SIGINT, syscall.SIGTERM)
			defer stop()

			srv, reg := server.New(logger)

			// Start the idle/lifetime reaper over the shared registry; stopReaper
			// halts and joins the sweep goroutine. On any return path, drain the
			// registry with CloseAll so no supervised funpack child group is orphaned
			// — the reaper only evicts the idle, CloseAll closes EVERY live session.
			reaper := session.NewReaper(reg, session.ReaperConfig{IdleTTL: idleTTL, Tick: reaperTick}, logger)
			stopReaper := reaper.Start(ctx)
			defer func() {
				stopReaper()
				reg.CloseAll()
			}()

			logger.Info().Str("server", server.Name).Msg("funpack-mcp serving over stdio")

			err := srv.Run(ctx, &mcp.StdioTransport{})
			// Clean shutdown: a signal cancelled the context, or the client closed
			// stdin (EOF) — both are how an MCP stdio session normally ends.
			if err == nil || ctx.Err() != nil || errors.Is(err, io.EOF) {
				logger.Info().Msg("funpack-mcp stopped")
				return nil
			}
			return err
		},
	}
}
