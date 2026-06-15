package logging

import (
	"io"
	"strings"
	"time"

	"github.com/rs/zerolog"
)

// New builds a zerolog.Logger writing to w, which must be stderr in production:
// the MCP stdio transport owns stdout, so a stray log line there corrupts the
// JSON-RPC stream. level is a zerolog level name ("debug".."error", default
// info); format selects "json" (default, machine-readable) or "console"
// (human-readable, for local dev).
func New(w io.Writer, level, format string) zerolog.Logger {
	lvl, err := zerolog.ParseLevel(strings.ToLower(level))
	if err != nil || level == "" {
		lvl = zerolog.InfoLevel
	}

	if strings.EqualFold(format, "console") {
		w = zerolog.ConsoleWriter{Out: w, TimeFormat: time.RFC3339}
	}

	return zerolog.New(w).Level(lvl).With().Timestamp().Logger()
}
