package main

import (
	"fmt"
	"os"

	"github.com/mjmorales/funpack/mcp/internal/cmd"
)

func main() {
	if err := cmd.Execute(); err != nil {
		// Errors go to stderr, never stdout: stdout is the MCP stdio JSON-RPC stream.
		fmt.Fprintln(os.Stderr, "funpack-mcp:", err)
		os.Exit(1)
	}
}
