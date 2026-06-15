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

// caller is the §28 request seam the session-scoped tools resolve a session id to
// and drive every command through. It is exactly *session.Session's Call method,
// extracted as an interface so a test injects a FAKE caller (a canned-Response
// stub) and the control tools run against it with NO live runtime. Production
// resolves through session.Registry.Get, whose *Session satisfies this.
type caller interface {
	Call(ctx context.Context, cmd string, args json.RawMessage) (*contract.Response, error)
}

// controlResolve maps a session id to its caller and whether it is live. The
// production resolver is reg.Get adapted to the interface; tests inject a fake
// that returns a canned caller, so the control tools' resolve→Call→map path runs
// without a registry or a live attach.
type controlResolve func(id string) (caller, bool)

// --- §28.2/§28.3 control-group inputs ----------------------------------------
//
// Every control command is PERTURBING (contract.ClassControl): per spec §28 it
// NEVER mutates the canonical recording — it forks a NON-WARRANTED branch off a
// committed snapshot (an implicit fork at the canonical head when no branch is
// live) and perturbs only that branch. `checkout` is the lone non-perturbing arm:
// it forks nothing and only switches which already-committed lineage observe/time
// read. Each input carries the SessionID the command runs against plus the exact
// arg keys runtime/introspect_control.odin decodes — the field tags ARE the wire
// contract, so a mismatch is a decode refusal at the runtime, not a silent drop.

// InputRecord is one §23 action-snapshot entry: the player the action belongs to
// (P1..P4), the action named by its `Enum::Variant` registry token, and the analog
// slots the slot requires — a 1D `value` (the `values` list) or a 2D `x`/`y` (the
// `axes` list), each a Fixed raw-bit string. A digital button (pressed/held) names
// only player+action; the runtime resolves each entry through the program's action
// registry and refuses an unknown player/action/Fixed-encoding.
type InputRecord struct {
	Player string `json:"player" jsonschema:"the player the action belongs to: P1, P2, P3, or P4"`
	Action string `json:"action" jsonschema:"the action's Enum::Variant registry token"`
	Value  string `json:"value,omitempty" jsonschema:"1D analog value as a Fixed raw-bit string (values list only)"`
	X      string `json:"x,omitempty" jsonschema:"2D analog x as a Fixed raw-bit string (axes list only)"`
	Y      string `json:"y,omitempty" jsonschema:"2D analog y as a Fixed raw-bit string (axes list only)"`
}

// InjectInputInput feeds the §23 action-snapshot path on the branch: one
// deterministic input snapshot (pressed/held buttons, 1D values, 2D axes) folded
// `Ticks` full pipeline ticks through the same step_tick seam a live device feeds.
// Actions are named by their `Enum::Variant` token, players by P1..P4, analog
// values as Fixed raw-bit strings. Every list is optional; an omitted Ticks folds 1.
type InjectInputInput struct {
	SessionID string        `json:"session_id" jsonschema:"opaque id of the session to perturb (from session_start)"`
	Pressed   []InputRecord `json:"pressed,omitempty" jsonschema:"input records pressed THIS tick (player+action)"`
	Held      []InputRecord `json:"held,omitempty" jsonschema:"input records held DOWN (player+action)"`
	Values    []InputRecord `json:"values,omitempty" jsonschema:"1D analog records (player+action+value)"`
	Axes      []InputRecord `json:"axes,omitempty" jsonschema:"2D analog records (player+action+x+y)"`
	Ticks     int           `json:"ticks,omitempty" jsonschema:"number of full pipeline ticks to fold the snapshot through (>=1, default 1)"`
}

// SetInput forces one blackboard column on the branch — the debug-only write
// outside the own-blackboard path, executed through the ordinary tick transaction.
// The value decodes against the field's DECLARED type via the artifact literal
// codec; an observed value pastes straight back as the encoded payload.
type SetInput struct {
	SessionID string `json:"session_id" jsonschema:"opaque id of the session to perturb"`
	Thing     string `json:"thing" jsonschema:"the thing (table) declaring the field to force"`
	Field     string `json:"field" jsonschema:"the field/column to overwrite"`
	Value     string `json:"value" jsonschema:"the new value, encoded against the field's declared type (artifact literal encoding)"`
	Instance  int    `json:"instance,omitempty" jsonschema:"the instance id of the row to set (defaults to 0)"`
}

// SpawnInput mints one new instance on the branch through the ordinary
// tick-boundary spawn batch: the blackboard is the thing's declared defaults with
// the supplied Fields overrides (each encoded against its declared type). The
// minted instance id is surfaced in the result so the agent can address the row.
type SpawnInput struct {
	SessionID string            `json:"session_id" jsonschema:"opaque id of the session to perturb"`
	Thing     string            `json:"thing" jsonschema:"the thing (table) to spawn an instance of"`
	Fields    map[string]string `json:"fields,omitempty" jsonschema:"field overrides keyed by field name, each value encoded against the field's declared type; unspecified fields take the declared default"`
}

// DespawnInput is the despawn arm of the control group. The runtime control
// dispatcher does not yet handle a `despawn` command (it answers "unknown control
// command"), so this tool forwards the SessionID-scoped call as-is and surfaces
// whatever the runtime returns — when the runtime grows the arm, the wire shape it
// decodes lands here without a tool change.
type DespawnInput struct {
	SessionID string `json:"session_id" jsonschema:"opaque id of the session to perturb"`
	Thing     string `json:"thing,omitempty" jsonschema:"the thing (table) of the instance to despawn"`
	Instance  int    `json:"instance,omitempty" jsonschema:"the instance id of the row to despawn"`
}

// EmitInput injects one signal on the branch and folds a full pipeline tick over
// it: the decoded record is pre-routed into the tick's mailbox (the ordinary
// forward-routing shape), so every consumer reads it THIS tick. The value must
// decode to a record of the signal type.
type EmitInput struct {
	SessionID string `json:"session_id" jsonschema:"opaque id of the session to perturb"`
	Signal    string `json:"signal" jsonschema:"the signal type name to emit"`
	Value     string `json:"value" jsonschema:"the signal payload, encoded as a record of the signal type (artifact literal encoding)"`
}

// ReloadInput swaps the BRANCH onto a recompiled artifact through the gated atomic
// hot-reload swap: the branch head migrates through the schema-diff kernel and the
// branch program re-resolves against the new tables. A load/migration refusal is
// answered as an error and the branch keeps its last-good program untouched. The
// canonical chain and session program are NEVER touched.
type ReloadInput struct {
	SessionID string `json:"session_id" jsonschema:"opaque id of the session to perturb"`
	Artifact  string `json:"artifact" jsonschema:"path to the recompiled artifact to hot-reload the branch onto"`
}

// BranchInput is the EXPLICIT fork: snapshot the canonical chain at Tick (default:
// the canonical head) into a fresh branch — the git-like "what if?" fork. Re-issuing
// branch re-forks, discarding the prior branch lineage.
type BranchInput struct {
	SessionID string `json:"session_id" jsonschema:"opaque id of the session to fork a branch in"`
	Tick      *int   `json:"tick,omitempty" jsonschema:"the canonical tick to fork at (default: the canonical head); -1 forks post-startup"`
}

// CheckoutInput switches the session's ACTIVE lineage — the git-like checkout
// paired with branch's fork: branch creates the lineage, checkout makes it the one
// observe/time read WITHOUT a per-call branch arg. UNLIKE every other control
// command checkout is NON-perturbing: it forks nothing and mutates no recorded
// state, it only flips which already-committed lineage the resolver reads.
type CheckoutInput struct {
	SessionID string `json:"session_id" jsonschema:"opaque id of the session to switch the active lineage in"`
	Target    string `json:"target,omitempty" jsonschema:"which lineage to make active: 'branch' (default) or 'canonical'"`
}

// --- control output ----------------------------------------------------------

// ControlOutput is the uniform envelope every control tool returns: the §28
// response mapped through, with the perturbing/non-warranted branch lineage made
// first-class so the model never has to re-derive it.
//
// Result is the runtime's raw result object PASSED THROUGH verbatim (nil on a §28
// error response) — every command-specific field (spawn's minted `instance`,
// reload's `swapped`, checkout's `active`) survives here even though only the
// universal fields are decoded into typed slots. Branch is the forked lineage
// position the perturbing arms report; Active is the lineage checkout/status
// surface as in effect ("branch" or "canonical"); Warranted is the §28 §2 warranty
// of that lineage (always false for a perturbing fork, true only for the canonical
// trunk). All three are READ FROM the runtime result — never invented here.
type ControlOutput struct {
	Cmd       string          `json:"cmd" jsonschema:"the §28 command this result answers"`
	Branch    *BranchPosition `json:"branch,omitempty" jsonschema:"the forked (non-warranted) branch lineage position the perturbing control arms report"`
	Active    string          `json:"active,omitempty" jsonschema:"the lineage now in effect for observe/time reads: 'branch' or 'canonical' (checkout surfaces this)"`
	Warranted *bool           `json:"warranted,omitempty" jsonschema:"the §28 warranty of the surfaced lineage: false for a perturbing fork, true only for the canonical trunk"`
	Result    map[string]any  `json:"result,omitempty" jsonschema:"the verbatim runtime result object — carries every command-specific field (e.g. spawn's minted instance id, reload's swapped flag)"`
}

// BranchPosition is the forked lineage's position: the canonical tick it forked at
// and its own commit count since the fork. It mirrors the runtime's
// `result.branch` object exactly so an observed branch position pastes back.
type BranchPosition struct {
	BaseTick int `json:"base_tick" jsonschema:"the canonical tick the fork snapshotted (-1 = post-startup)"`
	Ticks    int `json:"ticks" jsonschema:"branch commits since the fork — the branch's own logical time"`
}

// controlResultView is the decode target for a control response's result object:
// only the fields the runtime control/checkout arms render. Absent fields stay at
// their zero value, and the raw result still travels through ControlOutput.Result
// for any command-specific field this view does not name.
type controlResultView struct {
	Branch    *BranchPosition `json:"branch"`
	Active    string          `json:"active"`
	Warranted *bool           `json:"warranted"`
}

// registerControlTools wires the §28 control-group tools against the shared
// Registry, resolving each session id to its *Session.Call via reg.Get. Use
// registerControlToolsWith to inject a fake resolver for a test that drives the
// control tools with a canned caller and NO live runtime.
func registerControlTools(srv *mcp.Server, logger zerolog.Logger, reg *session.Registry) {
	// Adapt reg.Get (returning the concrete *Session) to the caller interface:
	// *Session satisfies caller via its Call method. This is the only adaptation
	// the production path needs, and the lone non-testable edge the With form swaps.
	registerControlToolsWith(srv, logger, func(id string) (caller, bool) {
		s, ok := reg.Get(id)
		if !ok {
			return nil, false
		}
		return s, true
	})
}

// registerControlToolsWith is registerControlTools with the session-resolution
// seam injected, so a test drives every control tool against a fake caller (a
// canned-Response stub) with no registry and no live attach, while production
// passes reg.toCaller. The resolve seam is the ONLY non-testable edge — the arg
// marshalling, the §28 dispatch, the response mapping, and the unknown-id error
// all run identically with the fake.
func registerControlToolsWith(srv *mcp.Server, logger zerolog.Logger, resolve controlResolve) {
	registerControlTool(srv, logger, resolve, "control_inject_input",
		"Inject one §23 input snapshot on a session's branch and fold it forward. PERTURBING — forks a non-warranted branch off the canonical recording (never mutates the trunk).",
		contract.CmdInjectInput, func(in InjectInputInput) (string, any) {
			return in.SessionID, injectInputArgs{Pressed: in.Pressed, Held: in.Held, Values: in.Values, Axes: in.Axes, Ticks: in.Ticks}
		})

	registerControlTool(srv, logger, resolve, "control_set",
		"Force one blackboard field on a session's branch. PERTURBING — forks a non-warranted branch; the value decodes against the field's declared type.",
		contract.CmdSet, func(in SetInput) (string, any) {
			return in.SessionID, setArgs{Thing: in.Thing, Field: in.Field, Value: in.Value, Instance: in.Instance}
		})

	registerControlTool(srv, logger, resolve, "control_spawn",
		"Spawn one new instance of a thing on a session's branch and return the minted instance id. PERTURBING — forks a non-warranted branch.",
		contract.CmdSpawn, func(in SpawnInput) (string, any) {
			return in.SessionID, spawnArgs{Thing: in.Thing, Fields: in.Fields}
		})

	registerControlTool(srv, logger, resolve, "control_despawn",
		"Despawn one instance on a session's branch. PERTURBING — forks a non-warranted branch.",
		contract.CmdDespawn, func(in DespawnInput) (string, any) {
			return in.SessionID, despawnArgs{Thing: in.Thing, Instance: in.Instance}
		})

	registerControlTool(srv, logger, resolve, "control_emit",
		"Emit one signal on a session's branch and fold a full pipeline tick over it. PERTURBING — forks a non-warranted branch.",
		contract.CmdEmit, func(in EmitInput) (string, any) {
			return in.SessionID, emitArgs{Signal: in.Signal, Value: in.Value}
		})

	registerControlTool(srv, logger, resolve, "control_reload",
		"Hot-reload a session's BRANCH onto a recompiled artifact through the gated atomic swap. PERTURBING — forks a non-warranted branch; a load/migration refusal keeps the last-good program.",
		contract.CmdReload, func(in ReloadInput) (string, any) {
			return in.SessionID, reloadArgs{Artifact: in.Artifact}
		})

	registerControlTool(srv, logger, resolve, "control_branch",
		"Explicitly fork a session's canonical recording into a fresh non-warranted branch at a tick (default: the canonical head) — the git-like 'what if?' fork.",
		contract.CmdBranch, func(in BranchInput) (string, any) {
			return in.SessionID, branchArgs{Tick: in.Tick}
		})

	registerControlTool(srv, logger, resolve, "control_checkout",
		"Switch a session's ACTIVE lineage (observe/time read source) to 'branch' (default) or 'canonical'. NON-perturbing — navigates existing lineages, forks nothing.",
		contract.CmdCheckout, func(in CheckoutInput) (string, any) {
			return in.SessionID, checkoutArgs{Target: in.Target}
		})
}

// --- runtime arg shapes (match runtime/introspect_control.odin exactly) -------
//
// These are the args OBJECTS the runtime control arms decode. Each field tag is
// the exact key the matching json_*_field / json_array_field read pulls — the
// tool's typed input maps onto one of these before the §28 Call. `omitempty`
// elides an unset optional so the runtime takes its documented default (e.g. a
// missing `ticks` folds 1, a missing `tick` forks the canonical head).

type injectInputArgs struct {
	Pressed []InputRecord `json:"pressed,omitempty"`
	Held    []InputRecord `json:"held,omitempty"`
	Values  []InputRecord `json:"values,omitempty"`
	Axes    []InputRecord `json:"axes,omitempty"`
	Ticks   int           `json:"ticks,omitempty"`
}

type setArgs struct {
	Thing    string `json:"thing"`
	Field    string `json:"field"`
	Value    string `json:"value"`
	Instance int    `json:"instance,omitempty"`
}

type spawnArgs struct {
	Thing  string            `json:"thing"`
	Fields map[string]string `json:"fields,omitempty"`
}

type despawnArgs struct {
	Thing    string `json:"thing,omitempty"`
	Instance int    `json:"instance,omitempty"`
}

type emitArgs struct {
	Signal string `json:"signal"`
	Value  string `json:"value"`
}

type reloadArgs struct {
	Artifact string `json:"artifact"`
}

type branchArgs struct {
	Tick *int `json:"tick,omitempty"`
}

type checkoutArgs struct {
	Target string `json:"target,omitempty"`
}

// registerControlTool is the shared wiring for one control tool: it builds the
// typed handler that extracts the session id + the runtime args from In, resolves
// the caller (unknown id → invalid_input tool error), issues the §28 Call, and
// maps the Response into a ControlOutput. argsOf returns the (session id, runtime
// args object) for the typed input — the only per-command variation; everything
// else (resolve, marshal, call, map) is identical across the eight commands.
func registerControlTool[In any](
	srv *mcp.Server,
	logger zerolog.Logger,
	resolve controlResolve,
	name string,
	description string,
	cmd contract.Command,
	argsOf func(In) (string, any),
) {
	mcp.AddTool(srv, &mcp.Tool{Name: name, Description: description},
		func(ctx context.Context, _ *mcp.CallToolRequest, in In) (*mcp.CallToolResult, ControlOutput, error) {
			sessionID, argsObj := argsOf(in)
			if sessionID == "" {
				logger.Debug().Str("tool", name).Msg("control empty session id")
				res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategoryInvalidInput, "session_id must not be empty"))
				return res, ControlOutput{}, protoErr
			}

			c, ok := resolve(sessionID)
			if !ok {
				logger.Debug().Str("tool", name).Str("session_id", sessionID).Msg("control unknown session id")
				res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategoryInvalidInput, "unknown session id: "+sessionID))
				return res, ControlOutput{}, protoErr
			}

			args, err := json.Marshal(argsObj)
			if err != nil {
				logger.Debug().Err(err).Str("tool", name).Msg("control marshal args failed")
				res, protoErr := mcperr.ToolError(mcperr.Wrap(mcperr.CategoryInternal, "encoding the control command arguments failed", err))
				return res, ControlOutput{}, protoErr
			}

			resp, err := c.Call(ctx, string(cmd), args)
			if err != nil {
				logger.Debug().Err(err).Str("tool", name).Str("session_id", sessionID).Msg("control call failed")
				res, protoErr := mcperr.ToolError(mcperr.Wrap(mcperr.CategorySession, "the control command did not complete", err))
				return res, ControlOutput{}, protoErr
			}

			return mapControlResponse(logger, name, resp)
		})
}

// mapControlResponse turns a §28 control Response into the tool result. A
// not-ok response (a runtime refusal — out-of-range tick, unknown thing, a reload
// migration refusal) becomes a structured invalid_input IsError envelope the model
// reads and self-corrects from. An ok response decodes the universal branch /
// active-lineage / warranty fields into typed slots AND passes the full result
// through verbatim, so every command-specific field survives. A malformed response
// (ok but no result, or a result that does not parse) is an internal tool error.
func mapControlResponse(logger zerolog.Logger, name string, resp *contract.Response) (*mcp.CallToolResult, ControlOutput, error) {
	if !resp.Ok {
		msg := "the control command was refused"
		if resp.Error != nil {
			msg = *resp.Error
		}
		logger.Debug().Str("tool", name).Str("cmd", resp.Cmd).Str("error", msg).Msg("control runtime refusal")
		res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategoryInvalidInput, msg))
		return res, ControlOutput{}, protoErr
	}

	if resp.Result == nil {
		logger.Debug().Str("tool", name).Msg("control ok response carried no result")
		res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategoryInternal, "the control command returned ok with no result"))
		return res, ControlOutput{}, protoErr
	}

	// Decode the result once into the field map (the verbatim passthrough) and once
	// into the typed view (the universal branch/active/warranty slots). The map is
	// the source of truth for command-specific fields; the view lifts the shared
	// ones the model should not have to re-derive.
	raw := make(map[string]any)
	if err := json.Unmarshal(*resp.Result, &raw); err != nil {
		logger.Debug().Err(err).Str("tool", name).Msg("control result did not decode")
		res, protoErr := mcperr.ToolError(mcperr.Wrap(mcperr.CategoryInternal, "the control result did not decode", err))
		return res, ControlOutput{}, protoErr
	}
	var view controlResultView
	if err := json.Unmarshal(*resp.Result, &view); err != nil {
		logger.Debug().Err(err).Str("tool", name).Msg("control result fields did not decode")
		res, protoErr := mcperr.ToolError(mcperr.Wrap(mcperr.CategoryInternal, "the control result fields did not decode", err))
		return res, ControlOutput{}, protoErr
	}

	logger.Debug().Str("tool", name).Str("cmd", resp.Cmd).Msg("control ok")
	return nil, ControlOutput{
		Cmd:       resp.Cmd,
		Branch:    view.Branch,
		Active:    view.Active,
		Warranted: view.Warranted,
		Result:    raw,
	}, nil
}
