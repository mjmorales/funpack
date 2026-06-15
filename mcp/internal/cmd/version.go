package cmd

import (
	"github.com/mjmorales/funpack/mcp/internal/buildinfo"
	"github.com/spf13/cobra"
)

// newVersionCommand prints build metadata to stdout. Unlike serve, version is a
// plain CLI invocation with no MCP session, so stdout is the correct sink.
func newVersionCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print funpack-mcp build version",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			cmd.Printf("funpack-mcp %s (commit %s, built %s)\n",
				buildinfo.Version, buildinfo.Commit, buildinfo.Date)
			return nil
		},
	}
}
