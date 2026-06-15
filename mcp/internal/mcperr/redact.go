package mcperr

import (
	"strconv"

	"github.com/rs/zerolog"
)

// redactMask is the fixed replacement substituted for the body of a secret. It
// is a constant string with no relation to any input, so a masked value can
// never echo the secret it stands in for.
const redactMask = "****"

// Redact returns a log-safe rendering of a secret that NEVER returns the input.
// Empty stays empty; a short secret (<=4 runes) collapses to the fixed mask
// alone; a longer one becomes "<first><mask><last> (len=N)" — enough to
// distinguish two values and confirm length without leaking the secret.
//
// §28 SESSION TASKS MUST pass auth tokens AND loopback ports through Redact
// before logging them. The MCP stdio transport owns stdout and logs go to
// stderr, but stderr is still captured: a token or port printed verbatim in a
// log line is a leak. Route every such value through Redact first.
func Redact(secret string) string {
	r := []rune(secret)
	switch n := len(r); {
	case n == 0:
		return ""
	case n <= 4:
		return redactMask
	default:
		return string(r[0]) + redactMask + string(r[n-1]) + " (len=" + strconv.Itoa(n) + ")"
	}
}

// RedactPort renders a loopback port for logging via Redact, so the §28 session
// tasks have a typed entry point and cannot accidentally log the raw int. It
// masks the digits the same way Redact masks a token.
func RedactPort(port int) string {
	return Redact(strconv.Itoa(port))
}

// LogRedacted adds a string field to a zerolog event with its value passed
// through Redact, the secret-safe alternative to event.Str for any sensitive
// field. Returns the event for chaining: log.Info().Str("k", v); becomes
// mcperr.LogRedacted(log.Info(), "token", tok).Msg("connected").
func LogRedacted(e *zerolog.Event, key, secret string) *zerolog.Event {
	return e.Str(key, Redact(secret))
}
