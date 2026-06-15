package cmd

import (
	"errors"
	"io"
	"os/signal"
	"syscall"

	"github.com/mjmorales/funpack/mcp/internal/server"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/spf13/cobra"
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

			srv := server.New(logger)
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
