package cmd

import (
	"errors"
	"io"
	"os/signal"
	"syscall"
	"time"

	"github.com/mjmorales/funpack/mcp/internal/funpack"
	"github.com/mjmorales/funpack/mcp/internal/server"
	"github.com/mjmorales/funpack/mcp/internal/session"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
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

// resolveFunpack and preflightFunpack are the funpack-resolution seam serve gates
// startup on, indirected through package vars so a unit test can drive the three
// startup outcomes (not-found → warn, in-range → proceed, out-of-range → refuse)
// without execing a real funpack. Production wiring is the package defaults below;
// tests swap them and restore in a defer.
var (
	resolveFunpack   = funpack.Resolve
	preflightFunpack = funpack.Preflight
)

// startupPreflight runs the funpack resolve+preflight gate before the server binds
// its transport. It returns a fatal error ONLY when a resolvable funpack reports a
// schema OUTSIDE the supported range — an incompatible funpack would feed the
// tools garbage, so serve fails closed at startup. A funpack that cannot be found
// is NOT fatal: the docs/search tools need no funpack, so serve proceeds and the
// funpack-backed tools error per-call; this case logs a WARNING. The two failure
// kinds are kept distinct — resolve-miss vs preflight-mismatch — rather than
// collapsed into one fatal, because they share the resolver error category.
func startupPreflight(logger zerolog.Logger) error {
	bin, err := resolveFunpack()
	if err != nil {
		// Identity, NOT errors.Is: every resolver error is CategoryResolver and
		// mcperr.(*Error).Is compares by category, so errors.Is(err, ErrNotFound)
		// matches EVERY resolver failure (including a version-probe failure) and
		// would mislabel a located-but-too-old funpack as "not found". ErrNotFound is
		// returned by identity from locate(), so == distinguishes it correctly.
		if err == funpack.ErrNotFound {
			logger.Warn().Err(err).Msg("funpack binary not found — funpack-backed tools will error per-call; serving docs tools regardless")
			return nil
		}
		// A located-but-unusable funpack (most commonly one older than v0.7.0, so
		// `funpack version --json` fails; or a non-executable $FUNPACK_BIN) is also
		// non-fatal: docs tools need no funpack, and the err already names the path
		// and the upgrade fix. Distinct from "not found" so the operator does not
		// chase a phantom PATH problem. Warn and proceed.
		logger.Warn().Err(err).Msg("funpack found but its version probe failed — funpack-backed tools will error per-call; serving docs tools regardless (see error for the fix)")
		return nil
	}

	if err := preflightFunpack(bin); err != nil {
		// Schema mismatch: refuse. Returning the error from RunE exits serve
		// non-zero with the got/want detail; main.go renders it to stderr.
		return err
	}

	logger.Info().Str("funpack", bin.Path).Str("funpack_version", bin.Version.Version).Msg("funpack resolved and schema-compatible")
	return nil
}

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

			// Gate startup on funpack schema compatibility BEFORE binding the
			// transport: a schema-incompatible funpack fails closed here.
			if err := startupPreflight(logger); err != nil {
				return err
			}

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
