package server

import (
	"context"
	"encoding/json"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
	"github.com/mjmorales/funpack/mcp/internal/session"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// caller is the one §28 request seam the session-scoped tool groups (self-heal
// here; time/inspect/control elsewhere) drive every command through. The
// production caller is *session.Session (its Call issues a request and awaits the
// correlated response over the live attach); a test injects a FAKE caller that
// returns canned contract.Responses, so the tool's Call-and-map logic drives with
// no live runtime. Held narrow on purpose — three methods is one-pass reasoning.
type caller interface {
	Call(ctx context.Context, cmd string, args json.RawMessage) (*contract.Response, error)
}

// callerResolver maps an opaque session id to its caller. The production resolver
// is the shared Registry's Get (adapted so the concrete *session.Session satisfies
// the caller interface); a test injects a resolver over a FAKE caller so the §28
// command path drives without a registry or a live attach.
type callerResolver func(id string) (caller, bool)

// CaptureTestInput names the recorded session and the behavior-instance-at-tick
// the capture extracts. Instance is optional: omit it to take the first instance
// in fold order (the runtime's default), set it to target one specific Thing.
type CaptureTestInput struct {
	SessionID string `json:"session_id" jsonschema:"opaque id of the session to capture from, as returned by session_start"`
	Behavior  string `json:"behavior" jsonschema:"name of the behavior whose step to capture into a regression test"`
	Tick      int    `json:"tick" jsonschema:"the recorded tick at which to capture the behavior's (self, resources, inbound signals)"`
	Instance  *int   `json:"instance,omitempty" jsonschema:"optional Thing id to target one behavior instance; omit to take the first instance in fold order"`
}

// CaptureTestOutput carries the emitted funpack test block — the
// debugger-output-IS-a-regression-test payoff. Test is a complete, idiomatic
// `test "…" { … }` source string the author folds into the project verbatim;
// Tick/Behavior/Instance echo the provenance the runtime resolved the capture to.
type CaptureTestOutput struct {
	Tick     int    `json:"tick" jsonschema:"the recorded tick the capture was taken at"`
	Behavior string `json:"behavior" jsonschema:"the behavior the capture was taken from"`
	Instance int    `json:"instance" jsonschema:"the resolved Thing id of the captured behavior instance"`
	Test     string `json:"test" jsonschema:"the complete idiomatic funpack test block (source) to fold into the project as a permanent regression"`
}

// AuditInput names the recorded session to audit. The audit is a whole-run
// property (a single diverging tick breaks the warranty), so it takes no
// per-tick argument beyond the session handle.
type AuditInput struct {
	SessionID string `json:"session_id" jsonschema:"opaque id of the session to audit, as returned by session_start"`
}

// AuditOutput is the determinism-warranty verdict: Warranted is the one-value
// answer — true when the independent re-fold reproduced every recorded frame
// digest bit-identically, false the moment any tick diverged. On a divergence the
// Diverged block localizes the failure at its FIRST diverging tick with the
// recorded-vs-reproduced digest pair. RecordedSession/ReproducedSession are the
// whole-run digest summaries (equal under a warranted recording).
type AuditOutput struct {
	Warranted         bool             `json:"warranted" jsonschema:"true when the re-fold reproduced every recorded frame digest bit-identically; false on any divergence"`
	TicksAudited      int              `json:"ticks_audited" jsonschema:"the recorded tick count the re-fold reproduced (the audited extent)"`
	RecordedSession   uint64           `json:"recorded_session" jsonschema:"whole-run digest of the recorded chain"`
	ReproducedSession uint64           `json:"reproduced_session" jsonschema:"whole-run digest of the independent re-fold; equals recorded_session under a warranted recording"`
	Diverged          *DivergenceFrame `json:"diverged,omitempty" jsonschema:"present only when warranted is false: the first diverging tick and the recorded-vs-reproduced digest diff"`
}

// DivergenceFrame is the §28 §3 `diverged` payload localized to its first
// diverging tick: the committed tick ordinal, the digest the recording warranted,
// and the digest the fresh re-fold produced — the exact pair a determinism
// comparison fails on.
type DivergenceFrame struct {
	Tick       int    `json:"tick" jsonschema:"the first committed tick whose digest diverged"`
	Recorded   uint64 `json:"recorded" jsonschema:"the frame digest the recording carried at that tick"`
	Reproduced uint64 `json:"reproduced" jsonschema:"the frame digest the fresh re-fold produced at that tick"`
}

// registerSelfHealTools wires the §28 self-heal group (capture_test + audit) — the
// observe-class self-heal commands — against the shared Registry the server
// constructs. It resolves a session id to its caller through reg.Get; for a test
// that must drive without a live attach, use registerSelfHealToolsWith with an
// injected resolver over a fake caller.
func registerSelfHealTools(srv *mcp.Server, logger zerolog.Logger, reg *session.Registry) {
	registerSelfHealToolsWith(srv, logger, func(id string) (caller, bool) {
		// reg.Get returns the concrete *session.Session, which satisfies caller; the
		// adapter widens the (typed-nil-safe) miss to (caller, bool) so the registry
		// stays unaware of the caller interface.
		s, ok := reg.Get(id)
		if !ok {
			return nil, false
		}
		return s, true
	})
}

// registerSelfHealToolsWith is registerSelfHealTools with the id→caller resolve
// seam injected, so a test drives capture_test/audit against a FAKE caller (no
// registry, no live runtime) while production passes a resolver over the shared
// Registry. The resolve seam is the ONLY non-testable edge — everything else (arg
// marshalling, the Call, the Response Ok/Result/Error mapping, the unknown-id and
// §28-error envelopes) runs identically with the fake.
//
// reg.Get returns (*session.Session, bool); *session.Session satisfies caller, so
// registerSelfHealTools adapts it to a callerResolver inline at the call site
// rather than asking the registry to know about the caller interface.
func registerSelfHealToolsWith(srv *mcp.Server, logger zerolog.Logger, resolve callerResolver) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "capture_test",
		Description: "Capture one behavior instance's step at a recorded tick into a complete, idiomatic funpack test block, ready to fold into the project as a permanent regression. Observe-class: reads the recording, never perturbs it.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in CaptureTestInput) (*mcp.CallToolResult, CaptureTestOutput, error) {
		c, ok := resolve(in.SessionID)
		if !ok {
			logger.Debug().Str("session_id", in.SessionID).Msg("capture_test unknown session")
			res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategoryInvalidInput, "unknown session id: "+in.SessionID))
			return res, CaptureTestOutput{}, protoErr
		}

		args, err := json.Marshal(captureArgs{Tick: in.Tick, Behavior: in.Behavior, Instance: in.Instance})
		if err != nil {
			res, protoErr := mcperr.ToolError(mcperr.Wrap(mcperr.CategoryInternal, "marshalling capture_test args failed", err))
			return res, CaptureTestOutput{}, protoErr
		}

		resp, err := c.Call(ctx, string(contract.CmdCaptureTest), args)
		if err != nil {
			logger.Debug().Err(err).Str("session_id", in.SessionID).Msg("capture_test call failed")
			res, protoErr := mcperr.ToolError(err)
			return res, CaptureTestOutput{}, protoErr
		}
		if errRes, protoErr, isErr := selfHealResponseError(resp); isErr {
			logger.Debug().Str("session_id", in.SessionID).Msg("capture_test §28 error response")
			return errRes, CaptureTestOutput{}, protoErr
		}

		var out CaptureTestOutput
		if err := json.Unmarshal(*resp.Result, &out); err != nil {
			res, protoErr := mcperr.ToolError(mcperr.Wrap(mcperr.CategoryProtocol, "decoding capture_test result failed", err))
			return res, CaptureTestOutput{}, protoErr
		}
		logger.Debug().Str("session_id", in.SessionID).Str("behavior", out.Behavior).Int("tick", out.Tick).Msg("capture_test emitted")
		return nil, out, nil
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "audit",
		Description: "Re-fold the recording from its snapshot+seed and confirm the re-run reproduces every recorded frame digest bit-identically — the determinism-warranty audit. Returns warranted=true on a clean re-fold, or warranted=false with the first diverging tick and digest diff. Observe-class: leaves the recording byte-unchanged.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in AuditInput) (*mcp.CallToolResult, AuditOutput, error) {
		c, ok := resolve(in.SessionID)
		if !ok {
			logger.Debug().Str("session_id", in.SessionID).Msg("audit unknown session")
			res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategoryInvalidInput, "unknown session id: "+in.SessionID))
			return res, AuditOutput{}, protoErr
		}

		// audit takes no args: it audits the WHOLE recording the session holds.
		resp, err := c.Call(ctx, string(contract.CmdAudit), nil)
		if err != nil {
			logger.Debug().Err(err).Str("session_id", in.SessionID).Msg("audit call failed")
			res, protoErr := mcperr.ToolError(err)
			return res, AuditOutput{}, protoErr
		}
		if errRes, protoErr, isErr := selfHealResponseError(resp); isErr {
			logger.Debug().Str("session_id", in.SessionID).Msg("audit §28 error response")
			return errRes, AuditOutput{}, protoErr
		}

		var out AuditOutput
		if err := json.Unmarshal(*resp.Result, &out); err != nil {
			res, protoErr := mcperr.ToolError(mcperr.Wrap(mcperr.CategoryProtocol, "decoding audit result failed", err))
			return res, AuditOutput{}, protoErr
		}
		logger.Debug().Str("session_id", in.SessionID).Bool("warranted", out.Warranted).Int("ticks", out.TicksAudited).Msg("audit verdict")
		return nil, out, nil
	})
}

// captureArgs is the wire shape of the capture_test command's args object — the
// fields runtime/introspect_capture.odin reads (tick + behavior required, instance
// optional). It mirrors the runtime arg contract, not the MCP input envelope.
type captureArgs struct {
	Tick     int    `json:"tick"`
	Behavior string `json:"behavior"`
	Instance *int   `json:"instance,omitempty"`
}

// selfHealResponseError maps a §28 Response onto the tool boundary: a Response with
// Ok=false (or a malformed one missing its Result on Ok) becomes a session-category
// IsError envelope the model reads and self-corrects from. It returns isErr=false
// only when the Response is a well-formed success carrying a Result to decode.
func selfHealResponseError(resp *contract.Response) (*mcp.CallToolResult, error, bool) {
	if !resp.Ok {
		msg := "the runtime returned a §28 error response"
		if resp.Error != nil {
			msg = *resp.Error
		}
		res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategorySession, msg))
		return res, protoErr, true
	}
	if resp.Result == nil {
		res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategoryProtocol, "the runtime returned an ok response with no result"))
		return res, protoErr, true
	}
	return nil, nil, false
}
