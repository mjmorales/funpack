package server

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/png"
	"strings"

	"github.com/mjmorales/funpack/mcp/internal/contract"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
	"github.com/mjmorales/funpack/mcp/internal/qoi"
	"github.com/mjmorales/funpack/mcp/internal/session"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// caller, callerResolver, registryResolver, unknownSession, mapResponseError, and
// decodeResult are declared once in time_tools.go (same package) and shared across
// every session-scoped tool group. The inspect group REUSES that seam — it adds no
// resolution machinery of its own beyond the per-command I/O schemas below.

// --- §28 inspect-group ("observe" class) I/O schemas -------------------------
//
// Every inspect tool takes {SessionID, ...cmd-specific args, branch?} and surfaces
// the §28 observe result verbatim. The arg/result shapes mirror the runtime source
// exactly (runtime/introspect.odin observe_* procs, dispatch ~line 438):
//
//   - signals          args: {tick}                 result: {tick, routes[]}
//   - pipeline         args: none                   result: {steps[]}
//   - trace            args: {tick, behavior}       result: {tick, behavior, steps[]}
//   - diff             args: {from, to}             result: {from, to, tables[]}
//   - replay_behavior  args: {tick, behavior}       result: {tick, behavior, instances[]}
//   - draw_list        args: {tick}                 result: {tick, commands[]}
//   - screenshot       args: {tick, include_drawlist?}  result: {tick, w, h, format, pixels, commands?}
//
// Every observe command ALSO accepts an optional `branch` selector (§28 observe
// addressing): absent ⇒ the canonical timeline, set ⇒ a checkout-created branch.
// Each input carries an optional Branch that is threaded into the args when set.

// InspectSignalsInput selects the session and the recorded tick whose routed
// signals to dump. The runtime re-folds that tick with the signal tap armed and
// renders every route in fold order.
type InspectSignalsInput struct {
	SessionID string  `json:"session_id" jsonschema:"opaque id of the live session, as returned by session_start"`
	Tick      int64   `json:"tick" jsonschema:"the recorded tick whose routed signals to dump"`
	Branch    *string `json:"branch,omitempty" jsonschema:"optional §28 observe-addressing selector: omit for the canonical timeline, set to a checkout-created branch name"`
}

// InspectPipelineInput selects the session whose §11 total-order pipeline to dump.
// pipeline is a pure read of the loaded program — it takes no per-tick argument.
type InspectPipelineInput struct {
	SessionID string  `json:"session_id" jsonschema:"opaque id of the live session, as returned by session_start"`
	Branch    *string `json:"branch,omitempty" jsonschema:"optional §28 observe-addressing selector: omit for the canonical timeline, set to a checkout-created branch name"`
}

// InspectTraceInput selects the session, the recorded tick, and the behavior whose
// per-instance (in → out) to trace. Both tick and behavior are required.
type InspectTraceInput struct {
	SessionID string  `json:"session_id" jsonschema:"opaque id of the live session, as returned by session_start"`
	Tick      int64   `json:"tick" jsonschema:"the recorded tick to trace the behavior at"`
	Behavior  string  `json:"behavior" jsonschema:"the behavior name whose per-instance (in → out) to trace"`
	Branch    *string `json:"branch,omitempty" jsonschema:"optional §28 observe-addressing selector: omit for the canonical timeline, set to a checkout-created branch name"`
}

// InspectDiffInput selects the session and the two retained ticks whose committed
// state delta to compute. Both from and to are required.
type InspectDiffInput struct {
	SessionID string  `json:"session_id" jsonschema:"opaque id of the live session, as returned by session_start"`
	From      int64   `json:"from" jsonschema:"the earlier retained tick of the diff"`
	To        int64   `json:"to" jsonschema:"the later retained tick of the diff"`
	Branch    *string `json:"branch,omitempty" jsonschema:"optional §28 observe-addressing selector: omit for the canonical timeline, set to a checkout-created branch name"`
}

// InspectReplayBehaviorInput selects the session, the recorded tick, and the
// behavior to re-run in isolation from its captured inputs (the §28 §1 purity
// theorem). Both tick and behavior are required.
type InspectReplayBehaviorInput struct {
	SessionID string  `json:"session_id" jsonschema:"opaque id of the live session, as returned by session_start"`
	Tick      int64   `json:"tick" jsonschema:"the recorded tick to replay the behavior at"`
	Behavior  string  `json:"behavior" jsonschema:"the behavior name to re-run in isolation from its captured inputs"`
	Branch    *string `json:"branch,omitempty" jsonschema:"optional §28 observe-addressing selector: omit for the canonical timeline, set to a checkout-created branch name"`
}

// InspectDrawListInput selects the session and the committed tick whose §20
// draw-list to dump — the sim-pure render projection that always serves (headless
// included), the deterministic twin of screenshot.
type InspectDrawListInput struct {
	SessionID string  `json:"session_id" jsonschema:"opaque id of the live session, as returned by session_start"`
	Tick      int64   `json:"tick" jsonschema:"the committed tick whose §20 draw-list to dump"`
	Branch    *string `json:"branch,omitempty" jsonschema:"optional §28 observe-addressing selector: omit for the canonical timeline, set to a checkout-created branch name"`
}

// InspectScreenshotInput selects the session and the committed tick to capture as a
// presented frame (pixels), with the deterministic draw-list optionally riding
// along. tick is required; IncludeDrawlist defaults to false (the lean visual-only
// capture). screenshot crosses the render/present boundary — it needs a FUNPACK_LIVE
// build; a headless runtime answers with a defined boundary refusal.
type InspectScreenshotInput struct {
	SessionID       string  `json:"session_id" jsonschema:"opaque id of the live session, as returned by session_start"`
	Tick            int64   `json:"tick" jsonschema:"the committed tick to capture as a presented frame"`
	IncludeDrawlist *bool   `json:"include_drawlist,omitempty" jsonschema:"when true, the deterministic §20 draw-list rides along with the pixels (default false: visual-only)"`
	Branch          *string `json:"branch,omitempty" jsonschema:"optional §28 observe-addressing selector: omit for the canonical timeline, set to a checkout-created branch name"`
}

// --- inspect result schemas (mirror the observe_* result JSON exactly) -------
//
// The runtime renders nested blackboard/value payloads (self_before, reads,
// result, row, diff from/to) as artifact-literal-encoded STRINGS via
// write_encoded_value / write_encoded_blackboard — so each lands here as a Go
// string carrying that encoding, exactly as the §28 wire emits it.

// SignalRoute is one routed signal during a recorded tick: the signal type, the
// per-instance target Id (null for a broadcast route), and the routed values as
// artifact-literal-encoded strings.
type SignalRoute struct {
	Signal string   `json:"signal" jsonschema:"the signal type name routed this tick"`
	Target *int64   `json:"target" jsonschema:"the per-instance target Id raw value, or null for a broadcast route"`
	Values []string `json:"values" jsonschema:"the routed values, each artifact-literal-encoded"`
}

// SignalsOutput is the signals result: the tick and every route in fold order.
type SignalsOutput struct {
	Tick   int64         `json:"tick" jsonschema:"the recorded tick the routes were re-folded from"`
	Routes []SignalRoute `json:"routes" jsonschema:"every signal route during the tick, in fold order"`
}

// PipelineStep is one §11 pipeline step: its total-order ordinal, the stage it
// belongs to, and the behavior it runs.
type PipelineStep struct {
	Ordinal  int64  `json:"ordinal" jsonschema:"the step's position in the §11 total order"`
	Stage    string `json:"stage" jsonschema:"the pipeline stage the step belongs to"`
	Behavior string `json:"behavior" jsonschema:"the behavior the step runs"`
}

// PipelineOutput is the pipeline result: the flattened §11 total order, exactly as
// the artifact carries it.
type PipelineOutput struct {
	Steps []PipelineStep `json:"steps" jsonschema:"the flattened §11 pipeline in total order"`
}

// TraceStep is one behavior instance's traced step for a recorded tick: the
// pre-eval blackboard, the bound reads (declared params in declaration order), the
// in-fold result, and the post-tick committed blackboard (null if despawned).
type TraceStep struct {
	Ordinal    int64             `json:"ordinal" jsonschema:"the step's §11 total-order ordinal"`
	Instance   int64             `json:"instance" jsonschema:"the Thing instance Id raw value this step ran for"`
	SelfBefore string            `json:"self_before" jsonschema:"the pre-eval blackboard as a Thing(field=enc,…) record literal"`
	Reads      map[string]string `json:"reads" jsonschema:"the bound reads keyed by declared param name, each artifact-literal-encoded"`
	Ok         bool              `json:"ok" jsonschema:"whether the behavior body evaluated without a runtime refusal"`
	Result     string            `json:"result" jsonschema:"the behavior's returned value, artifact-literal-encoded"`
	SelfAfter  *string           `json:"self_after" jsonschema:"the post-tick committed blackboard record literal, or null if the tick despawned the instance"`
}

// TraceOutput is the trace result: the tick, the behavior, and one TraceStep per
// instance the behavior ran for.
type TraceOutput struct {
	Tick     int64       `json:"tick" jsonschema:"the recorded tick traced"`
	Behavior string      `json:"behavior" jsonschema:"the behavior traced"`
	Steps    []TraceStep `json:"steps" jsonschema:"one traced step per instance the behavior ran for"`
}

// DiffField is one changed column in a row delta: the field name and its from/to
// artifact-literal encodings (from is null when the column was absent at `from`).
type DiffField struct {
	Field string  `json:"field" jsonschema:"the changed column name"`
	From  *string `json:"from" jsonschema:"the column's value at the from tick, artifact-literal-encoded, or null if absent"`
	To    string  `json:"to" jsonschema:"the column's value at the to tick, artifact-literal-encoded"`
}

// DiffAddedRow is one row added between the two ticks: its Id and its whole
// blackboard as a record literal.
type DiffAddedRow struct {
	ID  int64  `json:"id" jsonschema:"the added row's Id raw value"`
	Row string `json:"row" jsonschema:"the added row's blackboard as a Thing(field=enc,…) record literal"`
}

// DiffChangedRow is one surviving row whose columns changed: its Id and the
// per-field deltas in sorted field-name order.
type DiffChangedRow struct {
	ID     int64       `json:"id" jsonschema:"the changed row's Id raw value"`
	Fields []DiffField `json:"fields" jsonschema:"the changed columns in sorted field-name order"`
}

// DiffTable is one table's committed-state delta between the two ticks: rows added,
// rows removed (by Id), and surviving rows whose columns changed. Tables with no
// delta are omitted by the runtime.
type DiffTable struct {
	Thing   string           `json:"thing" jsonschema:"the table (thing) name"`
	Added   []DiffAddedRow   `json:"added" jsonschema:"rows present at the to tick but not at the from tick"`
	Removed []int64          `json:"removed" jsonschema:"Id raw values present at the from tick but not at the to tick"`
	Changed []DiffChangedRow `json:"changed" jsonschema:"surviving rows whose columns changed"`
}

// DiffOutput is the diff result: the two ticks and the per-table committed-state
// delta between them.
type DiffOutput struct {
	From   int64       `json:"from" jsonschema:"the earlier tick of the diff"`
	To     int64       `json:"to" jsonschema:"the later tick of the diff"`
	Tables []DiffTable `json:"tables" jsonschema:"the per-table committed-state delta (unchanged tables omitted)"`
}

// ReplayInstance is one behavior instance's isolated re-run verdict: the captured
// in-fold result and whether the second isolated evaluation reproduced it bit for
// bit (refold_matches=false is a §28 §1 purity violation to file).
type ReplayInstance struct {
	Instance      int64  `json:"instance" jsonschema:"the Thing instance Id raw value re-run"`
	Ok            bool   `json:"ok" jsonschema:"whether the in-fold evaluation succeeded"`
	Result        string `json:"result" jsonschema:"the captured in-fold result, artifact-literal-encoded"`
	RefoldMatches bool   `json:"refold_matches" jsonschema:"true when the isolated re-run reproduced the in-fold result exactly; false is a purity violation"`
}

// ReplayBehaviorOutput is the replay_behavior result: the tick, the behavior, and
// one ReplayInstance per instance re-run in isolation.
type ReplayBehaviorOutput struct {
	Tick      int64            `json:"tick" jsonschema:"the recorded tick replayed"`
	Behavior  string           `json:"behavior" jsonschema:"the behavior replayed"`
	Instances []ReplayInstance `json:"instances" jsonschema:"one isolated re-run verdict per instance"`
}

// DrawListOutput is the draw_list result: the committed tick and its §20 draw-list
// rendered as text commands (the same encoding screenshot{include_drawlist} emits).
type DrawListOutput struct {
	Tick     int64    `json:"tick" jsonschema:"the committed tick whose draw-list this is"`
	Commands []string `json:"commands" jsonschema:"the §20 draw-list rendered as text commands"`
}

// ScreenshotOutput is the structured metadata accompanying the screenshot tool's
// image content block: the captured tick, the frame geometry, and the §20
// draw-list when include_drawlist was set. The pixels themselves do NOT travel
// here — they are decoded from QOI, re-encoded to PNG, and returned as an MCP image
// content block on the same result so the model can SEE the frame.
type ScreenshotOutput struct {
	Tick     int64    `json:"tick" jsonschema:"the committed tick captured"`
	Width    int      `json:"width" jsonschema:"the captured frame width in pixels"`
	Height   int      `json:"height" jsonschema:"the captured frame height in pixels"`
	Commands []string `json:"commands,omitempty" jsonschema:"the §20 draw-list as text commands when include_drawlist was set; omitted otherwise"`
}

// screenshotResult is the raw §28 screenshot response shape the tool decodes before
// transcoding the pixels: format is always "qoi", pixels is the base64-QOI payload.
type screenshotResult struct {
	Tick     int64    `json:"tick"`
	Width    int      `json:"width"`
	Height   int      `json:"height"`
	Format   string   `json:"format"`
	Pixels   string   `json:"pixels"`
	Commands []string `json:"commands,omitempty"`
}

// --- runtime arg shapes (match the observe_* json_*_field reads exactly) -----
//
// Each observe command reads its args by key; an unset optional `branch` is elided
// so the runtime defaults to the canonical timeline.

type inspectTickArgs struct {
	Tick   int64   `json:"tick"`
	Branch *string `json:"branch,omitempty"`
}

type inspectBranchOnlyArgs struct {
	Branch *string `json:"branch,omitempty"`
}

type inspectTickBehaviorArgs struct {
	Tick     int64   `json:"tick"`
	Behavior string  `json:"behavior"`
	Branch   *string `json:"branch,omitempty"`
}

type inspectDiffArgs struct {
	From   int64   `json:"from"`
	To     int64   `json:"to"`
	Branch *string `json:"branch,omitempty"`
}

type inspectScreenshotArgs struct {
	Tick            int64   `json:"tick"`
	IncludeDrawlist *bool   `json:"include_drawlist,omitempty"`
	Branch          *string `json:"branch,omitempty"`
}

// registerInspectTools wires the §28 inspect group (signals / pipeline / trace /
// diff / replay_behavior / draw_list / screenshot) — the observe-class inspection
// commands — against the shared Registry the server owns. Each tool resolves its
// {SessionID} to a caller through registryResolver(reg). For a test that drives the
// tools without a live runtime, use registerInspectToolsWith with an injected
// resolver handing back a fake caller.
func registerInspectTools(srv *mcp.Server, logger zerolog.Logger, reg *session.Registry) {
	registerInspectToolsWith(srv, logger, registryResolver(reg))
}

// registerInspectToolsWith is registerInspectTools with the caller-resolution seam
// injected, so a test registers the inspect tools against a fake resolver (a fake
// caller with canned §28 responses) and exercises every tool envelope — the
// unknown-id error, the args marshalling, the §28 ok:false → IsError mapping, the
// typed result decode, and the screenshot QOI→PNG image content block — with NO
// live funpack runtime. Production passes registryResolver(reg); this is the ONLY
// seam — everything else runs identically.
func registerInspectToolsWith(srv *mcp.Server, logger zerolog.Logger, resolve callerResolver) {
	// The six typed-result tools share one generic body (registerInspectTool):
	// resolve → marshal args → Call → map ok:false → decode the typed result. Only
	// the (session id, args object) extraction varies per command.
	registerInspectTool(srv, logger, resolve, "inspect_signals",
		"Dump the signals routed during one recorded tick — the §28 live dataflow as data. Re-folds the tick with the tap armed and returns every route (broadcast or per-instance) in fold order. Observe-class: reads the recording, never perturbs it.",
		contract.CmdSignals, func(in InspectSignalsInput) (string, any) {
			return in.SessionID, inspectTickArgs{Tick: in.Tick, Branch: in.Branch}
		}, func(out SignalsOutput) []any { return []any{out.Tick, len(out.Routes)} })

	registerInspectTool(srv, logger, resolve, "inspect_pipeline",
		"Dump the flattened §11 pipeline in total order — every step's ordinal, stage, and behavior, exactly as the artifact carries them. A pure read of the loaded program. Observe-class: never perturbs the recording.",
		contract.CmdPipeline, func(in InspectPipelineInput) (string, any) {
			return in.SessionID, inspectBranchOnlyArgs{Branch: in.Branch}
		}, func(out PipelineOutput) []any { return []any{len(out.Steps)} })

	registerInspectTool(srv, logger, resolve, "inspect_trace",
		"Trace one behavior's per-instance (in → out) at a recorded tick — the §28 §3 bounded re-fold (causality recomputed, not stored). Per instance: the pre-eval blackboard, the bound reads, the result, and the post-tick committed blackboard. Observe-class.",
		contract.CmdTrace, func(in InspectTraceInput) (string, any) {
			return in.SessionID, inspectTickBehaviorArgs{Tick: in.Tick, Behavior: in.Behavior, Branch: in.Branch}
		}, func(out TraceOutput) []any { return []any{out.Behavior, len(out.Steps)} })

	registerInspectTool(srv, logger, resolve, "inspect_diff",
		"Diff the committed state between two retained ticks — a pure read of two COW versions. Per table: the rows added, removed, and each surviving row's changed fields with from/to encodings. Unchanged tables are omitted. Observe-class.",
		contract.CmdDiff, func(in InspectDiffInput) (string, any) {
			return in.SessionID, inspectDiffArgs{From: in.From, To: in.To, Branch: in.Branch}
		}, func(out DiffOutput) []any { return []any{out.From, out.To, len(out.Tables)} })

	registerInspectTool(srv, logger, resolve, "inspect_replay_behavior",
		"Re-run one behavior in isolation from its captured inputs and confirm the isolated re-run reproduces the in-fold result — the §28 §1 purity theorem made checkable. refold_matches=false on any instance is a behavior reading outside its declared inputs (a bug to file). Observe-class.",
		contract.CmdReplayBehavior, func(in InspectReplayBehaviorInput) (string, any) {
			return in.SessionID, inspectTickBehaviorArgs{Tick: in.Tick, Behavior: in.Behavior, Branch: in.Branch}
		}, func(out ReplayBehaviorOutput) []any { return []any{out.Behavior, len(out.Instances)} })

	registerInspectTool(srv, logger, resolve, "inspect_draw_list",
		"Dump one committed tick's §20 draw-list — the deterministic render projection re-run post-hoc over the retained version. This is screenshot's sim-pure twin: it always serves (headless included), and the draw-list IS the determinism-path render output. Observe-class.",
		contract.CmdDrawList, func(in InspectDrawListInput) (string, any) {
			return in.SessionID, inspectTickArgs{Tick: in.Tick, Branch: in.Branch}
		}, func(out DrawListOutput) []any { return []any{out.Tick, len(out.Commands)} })

	// screenshot is the one inspect tool with depth: it transcodes the §28 QOI
	// pixel payload into a PNG image content block the model can visually inspect,
	// alongside the structured metadata. It does NOT share the generic body.
	registerScreenshotTool(srv, logger, resolve)
}

// registerInspectTool is the shared wiring for one typed-result inspect tool:
// resolve the caller (unknown id → invalid_input IsError), marshal the runtime
// args, issue the §28 Call, map an ok:false response to a session IsError envelope,
// and decode the typed result. argsOf extracts (session id, runtime args) from the
// typed input — the only per-command variation; logFields pulls a couple of debug
// fields off the decoded output. Everything else is identical across the six.
func registerInspectTool[In any, Out any](
	srv *mcp.Server,
	logger zerolog.Logger,
	resolve callerResolver,
	name string,
	description string,
	cmd contract.Command,
	argsOf func(In) (string, any),
	logFields func(Out) []any,
) {
	mcp.AddTool(srv, &mcp.Tool{Name: name, Description: description},
		func(ctx context.Context, _ *mcp.CallToolRequest, in In) (*mcp.CallToolResult, Out, error) {
			var zero Out
			sessionID, argsObj := argsOf(in)

			c, ok := resolve(sessionID)
			if !ok {
				res, protoErr := unknownSession(logger, name, sessionID)
				return res, zero, protoErr
			}

			args, err := json.Marshal(argsObj)
			if err != nil {
				res, protoErr := mcperr.ToolError(mcperr.Wrap(mcperr.CategoryInternal, "marshalling "+name+" args failed", err))
				return res, zero, protoErr
			}

			resp, err := c.Call(ctx, string(cmd), args)
			if err != nil {
				res, protoErr := mcperr.ToolError(err)
				return res, zero, protoErr
			}
			if res, protoErr, isErr := mapResponseError(resp, name); isErr {
				return res, zero, protoErr
			}

			var out Out
			if res, protoErr, failed := decodeResult(resp, name, &out); failed {
				return res, zero, protoErr
			}
			logger.Debug().Str("session_id", sessionID).Str("cmd", string(cmd)).Interface("fields", logFields(out)).Msg("inspect ok")
			return nil, out, nil
		})
}

// registerScreenshotTool wires inspect_screenshot, the one inspect tool that
// returns a real image. It resolves and calls §28 screenshot like the others, but
// then: base64-decodes the QOI pixels, decodes QOI → RGBA8, PNG-encodes the RGBA,
// and returns BOTH an MCP image content block (the visible frame) AND the typed
// ScreenshotOutput metadata on one result. A §28 refusal (ok:false — a headless /
// no-display runtime that cannot cross the present boundary) maps to a session
// IsError envelope through the SAME mapResponseError seam, never a decode attempt.
func registerScreenshotTool(srv *mcp.Server, logger zerolog.Logger, resolve callerResolver) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "inspect_screenshot",
		Description: "Capture one committed tick as a presented frame and return it as a PNG image the model can SEE, plus structured geometry metadata. Crosses the §28 render/present boundary — needs a FUNPACK_LIVE build; a headless runtime refuses (use inspect_draw_list for the sim-pure draw-list). Set include_drawlist to ride the deterministic draw-list along. Observe-class: re-projects a committed tick, perturbs nothing.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in InspectScreenshotInput) (*mcp.CallToolResult, ScreenshotOutput, error) {
		c, ok := resolve(in.SessionID)
		if !ok {
			res, protoErr := unknownSession(logger, "inspect_screenshot", in.SessionID)
			return res, ScreenshotOutput{}, protoErr
		}

		args, err := json.Marshal(inspectScreenshotArgs{Tick: in.Tick, IncludeDrawlist: in.IncludeDrawlist, Branch: in.Branch})
		if err != nil {
			res, protoErr := mcperr.ToolError(mcperr.Wrap(mcperr.CategoryInternal, "marshalling inspect_screenshot args failed", err))
			return res, ScreenshotOutput{}, protoErr
		}

		resp, err := c.Call(ctx, string(contract.CmdScreenshot), args)
		if err != nil {
			res, protoErr := mcperr.ToolError(err)
			return res, ScreenshotOutput{}, protoErr
		}
		// A funpack binary built WITHOUT FUNPACK_LIVE answers the present-boundary
		// crossing with a §28 ok:false refusal — own the precise diagnostic at THIS
		// boundary (the demux/session-bridge boundary pattern: the boundary owns its
		// message rather than forwarding the upstream string) rather than forwarding
		// the runtime string raw, and NEVER attempt a transcode over an absent payload.
		if res, protoErr, isErr := mapScreenshotRefusal(resp); isErr {
			return res, ScreenshotOutput{}, protoErr
		}

		var raw screenshotResult
		if res, protoErr, failed := decodeResult(resp, "inspect_screenshot", &raw); failed {
			return res, ScreenshotOutput{}, protoErr
		}

		pngBytes, transErr := qoiToPNG(raw.Pixels)
		if transErr != nil {
			logger.Debug().Err(transErr).Str("session_id", in.SessionID).Msg("inspect_screenshot transcode failed")
			res, protoErr := mcperr.ToolError(mcperr.Wrap(mcperr.CategoryInternal, "decoding the §28 QOI frame to PNG failed", transErr))
			return res, ScreenshotOutput{}, protoErr
		}

		out := ScreenshotOutput{Tick: raw.Tick, Width: raw.Width, Height: raw.Height, Commands: raw.Commands}
		// Pre-set Content so the SDK leaves it intact (it only auto-fills Content
		// from the typed Out when Content is nil) and still populates
		// StructuredContent from the returned ScreenshotOutput. The model both SEES
		// the PNG and reads the structured metadata.
		metaJSON, _ := json.Marshal(out)
		result := &mcp.CallToolResult{
			Content: []mcp.Content{
				&mcp.ImageContent{Data: pngBytes, MIMEType: "image/png"},
				&mcp.TextContent{Text: string(metaJSON)},
			},
		}
		logger.Debug().Str("session_id", in.SessionID).Int64("tick", raw.Tick).Int("w", raw.Width).Int("h", raw.Height).Msg("inspect_screenshot captured")
		return result, out, nil
	})
}

// mapScreenshotRefusal owns the inspect_screenshot present-boundary diagnostic at
// the MCP boundary, instead of forwarding the runtime's §28 error string verbatim
// the way the generic mapResponseError does (the demux/session-bridge boundary
// pattern: the boundary that knows the operation names the cause, it does not leak
// an upstream string a caller cannot reliably act on). screenshot is the one observe command that is NOT
// sim-pure — it crosses the render/present boundary, which a funpack binary built
// WITHOUT -define:FUNPACK_LIVE=true cannot serve (its session_capture_frame is the
// no-op stub). That capability is a compile-time property of the funpack BINARY, not
// of the built artifact: there is no per-artifact live flag to set, so the durable
// remedy is the deterministic twin — inspect_draw_list ALWAYS serves (headless
// included) and IS the determinism-path render output, the canonical headless
// screenshot substitute.
//
// On a §28 ok:false (the present-boundary refusal — or any screenshot refusal that
// is NOT a caller mistake like a bad tick), it emits the MCP's own structured
// CategorySession envelope naming the cause AND directing the caller to
// inspect_draw_list, preserving the runtime's original text as Detail for fidelity.
// A caller-side refusal (missing/out-of-range tick, unknown branch) is forwarded as
// the runtime stated it — that is the caller's input to fix, not a boundary the MCP
// must reframe. It returns isErr=false for an ok:true response, leaving the caller
// to decode + transcode.
func mapScreenshotRefusal(resp *contract.Response) (*mcp.CallToolResult, error, bool) {
	if resp.Ok {
		return nil, nil, false
	}
	runtimeText := ""
	if resp.Error != nil {
		runtimeText = *resp.Error
	}
	// A caller-input refusal is the caller's to fix — forward it unreframed so the
	// model corrects the argument rather than chasing the present boundary.
	if isScreenshotInputRefusal(runtimeText) {
		res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategorySession, runtimeText))
		return res, protoErr, true
	}
	e := mcperr.New(mcperr.CategorySession,
		"inspect_screenshot crosses the render/present boundary, which this funpack binary cannot serve — pixel capture needs a funpack built with FUNPACK_LIVE. Use inspect_draw_list for the deterministic render projection: it is screenshot's sim-pure twin and always serves headless (it IS the determinism-path render output)")
	if runtimeText != "" {
		e.Detail = "runtime: " + runtimeText
	}
	res, protoErr := mcperr.ToolError(e)
	return res, protoErr, true
}

// isScreenshotInputRefusal reports whether a §28 screenshot refusal is a caller-side
// argument mistake (a tick out of range, a missing tick, an unknown branch) rather
// than the present-boundary crossing. Those carry distinct fixed runtime text
// (runtime/introspect.odin observe_screenshot), and the caller fixes the ARGUMENT,
// so the MCP forwards them unreframed instead of pointing at inspect_draw_list. The
// match is on the runtime's stable refusal substrings — the present-boundary refusal
// (the FUNPACK_LIVE case) is everything else.
func isScreenshotInputRefusal(runtimeText string) bool {
	for _, marker := range []string{"tick out of range", "missing args.tick", "unknown branch"} {
		if strings.Contains(runtimeText, marker) {
			return true
		}
	}
	return false
}

// qoiToPNG decodes a base64-QOI screenshot payload into RGBA8 and re-encodes it as
// PNG bytes. It is the §28-pixels → model-visible-image transcode: base64-decode →
// QOI decode (the runtime's core:image/qoi encode, inverted) → RGBA8 → PNG. The
// decoded buffer is already the tight row-major RGBA the stdlib image.RGBA wants,
// so the PNG encode is a direct wrap with no channel shuffle.
func qoiToPNG(base64QOI string) ([]byte, error) {
	qoiBytes, err := base64.StdEncoding.DecodeString(base64QOI)
	if err != nil {
		return nil, err
	}
	rgba, header, err := qoi.Decode(qoiBytes)
	if err != nil {
		return nil, err
	}
	img := &image.RGBA{
		Pix:    rgba,
		Stride: int(header.Width) * 4,
		Rect:   image.Rect(0, 0, int(header.Width), int(header.Height)),
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
