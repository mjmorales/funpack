package server

import (
	"context"

	"github.com/mjmorales/funpack/mcp/internal/funpack"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
	"github.com/mjmorales/funpack/mcp/internal/session"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// sessionOpener is the seam session_start opens a supervised attach through. The
// production opener is session.Open (which needs a live FUNPACK_LIVE funpack
// attach, so it is not unit-testable); tests inject a fake that returns a
// pre-built *session.Session over an in-memory conn, so the tools' registry
// wiring drives without a real runtime.
type sessionOpener func(ctx context.Context, bin funpack.Binary, artifact string, cfg session.Config) (*session.Session, error)

// sessionResolver is the seam session_start resolves the funpack binary through
// before opening. The production resolver is funpack.Resolve (which shells out to
// `funpack version --json`, so it is not unit-testable without a real binary);
// tests inject a fake that returns a stub Binary so the open path drives without a
// funpack on PATH.
type sessionResolver func() (funpack.Binary, error)

// SessionStartInput names the artifact the supervised attach should load.
type SessionStartInput struct {
	Artifact string `json:"artifact" jsonschema:"path to the built funpack game artifact for the attach session to load"`
}

// SessionStartOutput is the handle a caller drives the session by: the opaque id
// (passed to session_end and the session-scoped tools) and the negotiated §28
// protocol version. No secret (auth token, loopback port) is ever surfaced.
type SessionStartOutput struct {
	SessionID         string `json:"session_id" jsonschema:"opaque handle for this session; pass to session_end and session-scoped tools"`
	NegotiatedVersion int    `json:"negotiated_version" jsonschema:"the §28 protocol version negotiated with the runtime"`
}

// SessionEndInput names the session to tear down by its opaque id.
type SessionEndInput struct {
	SessionID string `json:"session_id" jsonschema:"opaque id of the session to close, as returned by session_start"`
}

// SessionEndOutput confirms the close: the id that was torn down.
type SessionEndOutput struct {
	SessionID string `json:"session_id" jsonschema:"the id of the session that was closed"`
	Closed    bool   `json:"closed" jsonschema:"true when the session was found and torn down"`
}

// SessionListInput is empty: listing takes no arguments.
type SessionListInput struct{}

// SessionListOutput is the non-secret roster of live sessions, oldest first.
type SessionListOutput struct {
	Sessions []session.SessionInfo `json:"sessions" jsonschema:"live supervised attach sessions; no secrets (no token, no port)"`
}

// registerSessionTools wires the session-lifecycle tools (session_start /
// session_end / session_list) against the shared Registry the server constructs
// and the wave-6 reaper also keys on. The server owns the Registry's lifetime
// (construct in New, sweep on CloseAll); these tools only Add/Remove/List against
// it. session_start resolves through funpack.Resolve and opens through
// session.Open — for a test that must drive without a funpack on PATH or a live
// attach, use registerSessionToolsWith with injected resolver + opener seams.
func registerSessionTools(srv *mcp.Server, logger zerolog.Logger, reg *session.Registry) {
	registerSessionToolsWith(srv, logger, reg, funpack.Resolve, session.Open)
}

// registerSessionToolsWith is registerSessionTools with the resolve + open IO
// seams injected, so a test drives session_start/end/list against fakes (no
// funpack on PATH, no live runtime) while production passes funpack.Resolve and
// session.Open. Those two seams are the ONLY non-testable edges — everything else
// (registry Add/Remove/List, the tool envelopes, the unknown-id error) runs
// identically with the fakes.
func registerSessionToolsWith(srv *mcp.Server, logger zerolog.Logger, reg *session.Registry, resolve sessionResolver, open sessionOpener) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "session_start",
		Description: "Open a supervised funpack attach session over a built game artifact and register it. Returns an opaque session id and the negotiated protocol version.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in SessionStartInput) (*mcp.CallToolResult, SessionStartOutput, error) {
		if in.Artifact == "" {
			logger.Debug().Msg("session_start empty artifact")
			res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategoryInvalidInput, "artifact must not be empty"))
			return res, SessionStartOutput{}, protoErr
		}

		bin, err := resolve()
		if err != nil {
			logger.Debug().Err(err).Msg("session_start resolve funpack failed")
			res, protoErr := mcperr.ToolError(err)
			return res, SessionStartOutput{}, protoErr
		}

		sess, err := open(ctx, bin, in.Artifact, session.Config{Log: logger})
		if err != nil {
			logger.Debug().Err(err).Str("artifact", in.Artifact).Msg("session_start open failed")
			res, protoErr := mcperr.ToolError(err)
			return res, SessionStartOutput{}, protoErr
		}

		if err := reg.TryAdd(sess); err != nil {
			// At capacity: close the just-opened session so it does not leak as an
			// orphan (the child group is reaped), then surface the cap refusal as a
			// structured session-category tool error the model can read.
			_ = sess.Close()
			logger.Debug().Err(err).Str("artifact", in.Artifact).Msg("session_start refused: registry at capacity")
			res, protoErr := mcperr.ToolError(err)
			return res, SessionStartOutput{}, protoErr
		}
		logger.Info().Str("session_id", sess.ID()).Int("negotiated_v", sess.NegotiatedVersion()).Msg("session_start registered session")
		return nil, SessionStartOutput{
			SessionID:         sess.ID(),
			NegotiatedVersion: sess.NegotiatedVersion(),
		}, nil
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "session_end",
		Description: "Close a supervised funpack attach session by its id and deregister it. An unknown id is reported as an invalid_input tool error.",
	}, func(_ context.Context, _ *mcp.CallToolRequest, in SessionEndInput) (*mcp.CallToolResult, SessionEndOutput, error) {
		sess, ok := reg.Remove(in.SessionID)
		if !ok {
			logger.Debug().Str("session_id", in.SessionID).Msg("session_end unknown id")
			res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategoryInvalidInput, "unknown session id: "+in.SessionID))
			return res, SessionEndOutput{}, protoErr
		}
		// Remove already detached it from the registry; Close (idempotent, kills the
		// process group) runs outside the registry lock.
		closeErr := sess.Close()
		if closeErr != nil {
			// The session is deregistered regardless; a non-nil close error is the
			// loopback conn-close result, surfaced as a session-category tool error so
			// the model sees the teardown was imperfect without re-registering it.
			logger.Debug().Err(closeErr).Str("session_id", in.SessionID).Msg("session_end close error")
			res, protoErr := mcperr.ToolError(mcperr.Wrap(mcperr.CategorySession, "closing the session connection failed", closeErr))
			return res, SessionEndOutput{}, protoErr
		}
		logger.Info().Str("session_id", in.SessionID).Msg("session_end closed session")
		return nil, SessionEndOutput{SessionID: in.SessionID, Closed: true}, nil
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "session_list",
		Description: "List every live supervised funpack attach session (id, negotiated version, artifact, created-at). No secrets are returned.",
	}, func(_ context.Context, _ *mcp.CallToolRequest, _ SessionListInput) (*mcp.CallToolResult, SessionListOutput, error) {
		infos := reg.List()
		logger.Debug().Int("sessions", len(infos)).Msg("session_list")
		return nil, SessionListOutput{Sessions: infos}, nil
	})
}
