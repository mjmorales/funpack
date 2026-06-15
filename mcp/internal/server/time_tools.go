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

// caller is the one seam every session-scoped tool (time, and the later
// inspect/control/self-heal groups) issues a §28 command through: allocate a
// request id, encode the request, await the correlated response. It is satisfied
// by *session.Session (see session.Session.Call). The tools depend on this narrow
// interface — not on *session.Session — so a test injects a fake caller returning
// canned responses and drives every tool envelope with NO live funpack runtime.
type caller interface {
	Call(ctx context.Context, cmd string, args json.RawMessage) (*contract.Response, error)
}

// callerResolver maps an opaque session id to the caller for it. The production
// resolver reads the shared Registry (an unknown id → not found); a test injects a
// resolver that hands back a fake caller. registerTimeToolsWith takes this seam so
// the time tools register and run identically against a live registry and against
// fakes — it is the single injection point the time-group tests drive through, and
// the pattern the control/self-heal groups reuse.
type callerResolver func(id string) (caller, bool)

// registryResolver is the production callerResolver: it resolves a session id
// through the shared Registry the server owns, returning the live *session.Session
// (which satisfies caller) or not-found. The server wires the time tools with this
// after merge; the same Registry backs the inspect/control/self-heal groups.
func registryResolver(reg *session.Registry) callerResolver {
	return func(id string) (caller, bool) {
		s, ok := reg.Get(id)
		if !ok {
			return nil, false
		}
		return s, true
	}
}

// --- §28 time-group I/O schemas ----------------------------------------------
//
// Every time tool takes {SessionID, ...cmd-specific args} and surfaces the §28
// result for that command verbatim. The arg/result shapes mirror the runtime
// source exactly (runtime/introspect_time.odin):
//
//   - load   args: none                  result: {tick}
//   - run    args: {until?}              result: {tick}          (synchronous to target)
//   - pause  args: none                  result: {tick}          (idempotent position ack)
//   - step   args: none                  result: {tick}
//   - rewind args: {tick}  (required)    result: {tick, restored_from, refolded}
//   - reset  args: none                  result: {tick}
//   - status args: none                  result: the fixed status payload (TimeStatusOutput)

// TimeSessionInput is the bare session selector shared by the no-extra-arg time
// commands (load / pause / step / reset / status). The session id keys the live
// supervised attach the command rides.
type TimeSessionInput struct {
	SessionID string `json:"session_id" jsonschema:"opaque id of the live session, as returned by session_start"`
}

// TimeRunInput selects the session and the synchronous run target. Until is
// optional: omitted, run folds to the last recorded tick; set, run folds forward
// to that tick (a target behind the cursor is rewind's job and is refused by the
// runtime as such).
type TimeRunInput struct {
	SessionID string `json:"session_id" jsonschema:"opaque id of the live session, as returned by session_start"`
	Until     *int64 `json:"until,omitempty" jsonschema:"target tick to run forward to; omitted runs to the last recorded tick"`
}

// TimeRewindInput selects the session and the required rewind target tick. Rewind
// restores the nearest snapshot at-or-before tick and re-folds the recorded inputs
// forward to the exact target.
type TimeRewindInput struct {
	SessionID string `json:"session_id" jsonschema:"opaque id of the live session, as returned by session_start"`
	Tick      int64  `json:"tick" jsonschema:"target tick to rewind the cursor to (>= -1, within the recording)"`
}

// TimePositionOutput is the result of every position-only time command (load /
// run / pause / step / reset): the cursor's current tick is the whole payload.
type TimePositionOutput struct {
	Tick int64 `json:"tick" jsonschema:"the cursor's tick after the command (-1 is the post-startup base)"`
}

// TimeRewindOutput is rewind's result: the landed tick plus the bounded-replay
// shape made observable — the snapshot base it restored from and how many recorded
// ticks it re-folded forward to reach the target.
type TimeRewindOutput struct {
	Tick         int64 `json:"tick" jsonschema:"the cursor's tick after the rewind (the requested target)"`
	RestoredFrom int64 `json:"restored_from" jsonschema:"the snapshot base tick the rewind restored from before re-folding"`
	Refolded     int64 `json:"refolded" jsonschema:"how many recorded ticks were re-folded forward from the base to the target"`
}

// TimeStatusRing is the cursor's snapshot-ring shape inside the status payload:
// the fixed capacity, the live occupancy, and the occupied span (oldest/newest are
// null when the ring is empty).
type TimeStatusRing struct {
	Slots    int    `json:"slots" jsonschema:"the fixed ring capacity (a fixed engine budget)"`
	Occupied int    `json:"occupied" jsonschema:"how many ring slots are currently occupied"`
	Oldest   *int64 `json:"oldest" jsonschema:"oldest retained snapshot tick, or null when the ring is empty"`
	Newest   *int64 `json:"newest" jsonschema:"newest retained snapshot tick, or null when the ring is empty"`
}

// TimeStatusBranch is the active-lineage shape inside the status payload: whether
// a control fork exists and which lineage observe/time read by default.
type TimeStatusBranch struct {
	Live   bool   `json:"live" jsonschema:"true when a control fork (branch) exists off the canonical timeline"`
	Active string `json:"active" jsonschema:"the active lineage: canonical, or branch once a checkout makes the fork active"`
}

// TimeStatusOutput is the fixed status payload: load state, cursor position, the
// recording extent, seededness, the snapshot ring shape, and the active branch.
// Tick is null when no timeline is loaded.
type TimeStatusOutput struct {
	Loaded        bool             `json:"loaded" jsonschema:"true once load has armed the timeline cursor"`
	Tick          *int64           `json:"tick" jsonschema:"the cursor's tick, or null when no timeline is loaded"`
	TicksRecorded int              `json:"ticks_recorded" jsonschema:"total recorded ticks in the canonical timeline"`
	Seeded        bool             `json:"seeded" jsonschema:"true when the recorded run was seeded (rng is threaded through the fold)"`
	Cadence       int              `json:"cadence" jsonschema:"the fixed snapshot cadence: a ring snapshot is retained every Nth committed tick"`
	Ring          TimeStatusRing   `json:"ring" jsonschema:"the bounded snapshot ring shape (capacity, occupancy, span)"`
	Branch        TimeStatusBranch `json:"branch" jsonschema:"the active-lineage shape (whether a fork exists, which lineage is active)"`
}

// registerTimeTools wires the §28 time-group tools (load / run / pause / step /
// rewind / reset / status) against the shared Registry the server owns — the same
// Registry the session tools register into and the reaper sweeps. Each tool
// resolves its {SessionID} to a caller through registryResolver(reg). For a test
// that drives the tools without a live runtime, use registerTimeToolsWith with an
// injected resolver handing back a fake caller.
func registerTimeTools(srv *mcp.Server, logger zerolog.Logger, reg *session.Registry) {
	registerTimeToolsWith(srv, logger, registryResolver(reg))
}

// registerTimeToolsWith is registerTimeTools with the caller-resolution seam
// injected, so a test registers the time tools against a fake resolver (returning a
// fake caller with canned §28 responses) and exercises every tool envelope — the
// unknown-id error, the args marshalling, the §28 ok:false → IsError mapping, and
// the typed result decode — with NO live funpack runtime. Production passes
// registryResolver(reg); this is the ONLY seam — everything else runs identically.
func registerTimeToolsWith(srv *mcp.Server, logger zerolog.Logger, resolve callerResolver) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "time_load",
		Description: "Arm the §28 time cursor at the post-startup base (tick -1) for a session, readying the recorded timeline for navigation (run/step/rewind/reset). Re-issuing re-arms a fresh walk.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in TimeSessionInput) (*mcp.CallToolResult, TimePositionOutput, error) {
		return callTimePosition(ctx, logger, resolve, in.SessionID, contract.CmdLoad, nil)
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "time_run",
		Description: "Synchronously fold the recorded timeline forward to a target tick (default: the last recorded tick) and return the cursor position once reached. A target behind the cursor is refused — use time_rewind.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in TimeRunInput) (*mcp.CallToolResult, TimePositionOutput, error) {
		var args json.RawMessage
		if in.Until != nil {
			marshaled, err := json.Marshal(struct {
				Until int64 `json:"until"`
			}{Until: *in.Until})
			if err != nil {
				res, protoErr := mcperr.ToolError(mcperr.Wrap(mcperr.CategoryInvalidInput, "marshalling run args failed", err))
				return res, TimePositionOutput{}, protoErr
			}
			args = marshaled
		}
		return callTimePosition(ctx, logger, resolve, in.SessionID, contract.CmdRun, args)
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "time_pause",
		Description: "Acknowledge the §28 time cursor's current position (idempotent). Returns the cursor tick.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in TimeSessionInput) (*mcp.CallToolResult, TimePositionOutput, error) {
		return callTimePosition(ctx, logger, resolve, in.SessionID, contract.CmdPause, nil)
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "time_step",
		Description: "Advance the §28 time cursor one recorded tick. The end of the recording is refused, never a silent no-op. Returns the cursor tick.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in TimeSessionInput) (*mcp.CallToolResult, TimePositionOutput, error) {
		return callTimePosition(ctx, logger, resolve, in.SessionID, contract.CmdStep, nil)
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "time_rewind",
		Description: "Rewind the §28 time cursor to a target tick: restore the nearest snapshot at-or-before it and re-fold the recorded inputs forward to the exact target. Returns the landed tick plus the restore base and re-fold count.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in TimeRewindInput) (*mcp.CallToolResult, TimeRewindOutput, error) {
		c, ok := resolve(in.SessionID)
		if !ok {
			res, protoErr := unknownSession(logger, "time_rewind", in.SessionID)
			return res, TimeRewindOutput{}, protoErr
		}
		args, err := json.Marshal(struct {
			Tick int64 `json:"tick"`
		}{Tick: in.Tick})
		if err != nil {
			res, protoErr := mcperr.ToolError(mcperr.Wrap(mcperr.CategoryInvalidInput, "marshalling rewind args failed", err))
			return res, TimeRewindOutput{}, protoErr
		}
		resp, err := c.Call(ctx, string(contract.CmdRewind), args)
		if err != nil {
			res, protoErr := mcperr.ToolError(err)
			return res, TimeRewindOutput{}, protoErr
		}
		if res, protoErr, isErr := mapResponseError(resp, "time_rewind"); isErr {
			return res, TimeRewindOutput{}, protoErr
		}
		var out TimeRewindOutput
		if res, protoErr, failed := decodeResult(resp, "time_rewind", &out); failed {
			return res, TimeRewindOutput{}, protoErr
		}
		logger.Debug().Str("session_id", in.SessionID).Int64("tick", out.Tick).Msg("time_rewind ok")
		return nil, out, nil
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "time_reset",
		Description: "Return the §28 time cursor to the post-startup base (tick -1), keeping the snapshot ring. Returns the cursor tick.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in TimeSessionInput) (*mcp.CallToolResult, TimePositionOutput, error) {
		return callTimePosition(ctx, logger, resolve, in.SessionID, contract.CmdReset, nil)
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "time_status",
		Description: "Report the §28 time session shape: load state, cursor position, the recording extent, seededness, the snapshot ring (capacity/occupancy/span), and the active branch lineage.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in TimeSessionInput) (*mcp.CallToolResult, TimeStatusOutput, error) {
		c, ok := resolve(in.SessionID)
		if !ok {
			res, protoErr := unknownSession(logger, "time_status", in.SessionID)
			return res, TimeStatusOutput{}, protoErr
		}
		resp, err := c.Call(ctx, string(contract.CmdStatus), nil)
		if err != nil {
			res, protoErr := mcperr.ToolError(err)
			return res, TimeStatusOutput{}, protoErr
		}
		if res, protoErr, isErr := mapResponseError(resp, "time_status"); isErr {
			return res, TimeStatusOutput{}, protoErr
		}
		var out TimeStatusOutput
		if res, protoErr, failed := decodeResult(resp, "time_status", &out); failed {
			return res, TimeStatusOutput{}, protoErr
		}
		logger.Debug().Str("session_id", in.SessionID).Bool("loaded", out.Loaded).Msg("time_status ok")
		return nil, out, nil
	})
}

// callTimePosition is the shared handler body for every position-only time command
// (load / run / pause / step / reset): resolve the caller (unknown id → structured
// invalid_input error), issue the §28 command, map an ok:false response to an
// IsError envelope, and decode the {tick} result into the typed output.
func callTimePosition(
	ctx context.Context,
	logger zerolog.Logger,
	resolve callerResolver,
	sessionID string,
	cmd contract.Command,
	args json.RawMessage,
) (*mcp.CallToolResult, TimePositionOutput, error) {
	c, ok := resolve(sessionID)
	if !ok {
		res, protoErr := unknownSession(logger, string(cmd), sessionID)
		return res, TimePositionOutput{}, protoErr
	}
	resp, err := c.Call(ctx, string(cmd), args)
	if err != nil {
		res, protoErr := mcperr.ToolError(err)
		return res, TimePositionOutput{}, protoErr
	}
	if res, protoErr, isErr := mapResponseError(resp, string(cmd)); isErr {
		return res, TimePositionOutput{}, protoErr
	}
	var out TimePositionOutput
	if res, protoErr, failed := decodeResult(resp, string(cmd), &out); failed {
		return res, TimePositionOutput{}, protoErr
	}
	logger.Debug().Str("session_id", sessionID).Str("cmd", string(cmd)).Int64("tick", out.Tick).Msg("time position ok")
	return nil, out, nil
}

// unknownSession is the shared structured error for a tool call naming a session id
// that is not registered (or was reaped): an invalid_input IsError envelope the
// model reads and self-corrects from, never a protocol-level error.
func unknownSession(logger zerolog.Logger, tool, id string) (*mcp.CallToolResult, error) {
	logger.Debug().Str("tool", tool).Str("session_id", id).Msg("time tool unknown session id")
	return mcperr.ToolError(mcperr.New(mcperr.CategoryInvalidInput, "unknown session id: "+id))
}

// mapResponseError maps a §28 ok:false response to a session-category IsError
// envelope carrying the runtime's error text, so the model sees the §28 refusal
// (e.g. "no timeline loaded", "tick out of range") and can self-correct. It returns
// isErr=false for a successful (ok:true) response, leaving the caller to decode the
// result. A malformed response (ok:false with no error text) degrades to a generic
// session error rather than masking the failure.
func mapResponseError(resp *contract.Response, tool string) (*mcp.CallToolResult, error, bool) {
	if resp.Ok {
		return nil, nil, false
	}
	msg := tool + ": runtime refused the command"
	if resp.Error != nil {
		msg = *resp.Error
	}
	res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategorySession, msg))
	return res, protoErr, true
}

// decodeResult unmarshals the §28 response's result object into out. A successful
// response with an absent or unparseable result is an internal fault (the runtime
// broke its own contract), surfaced as an internal IsError envelope. It returns
// failed=false on a clean decode, leaving the typed out populated for the caller.
func decodeResult(resp *contract.Response, tool string, out any) (*mcp.CallToolResult, error, bool) {
	if resp.Result == nil {
		res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategoryInternal, tool+": ok response carried no result"))
		return res, protoErr, true
	}
	if err := json.Unmarshal(*resp.Result, out); err != nil {
		res, protoErr := mcperr.ToolError(mcperr.Wrap(mcperr.CategoryInternal, tool+": decoding the result payload failed", err))
		return res, protoErr, true
	}
	return nil, nil, false
}
