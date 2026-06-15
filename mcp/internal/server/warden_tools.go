package server

import (
	"context"

	"github.com/mjmorales/funpack/mcp/internal/funpack"
	"github.com/mjmorales/funpack/mcp/internal/funpackexec"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// WardenOutput is the uniform result every warden_* tool returns: the verbatim
// `funpack warden <sub>` outcome. Ok reflects the process exit, not a tool fault
// (see the exit-code contract below); Stdout carries the NDJSON / projection-text
// the warden subcommand emitted; ExitCode is the raw process status.
//
// THE EXIT-2 CONTRACT. A warden subcommand REFUSES with exit 2 when the committed
// .funpack/index.ndjson is missing, schema-mismatched, or malformed — it never
// recompiles. That refusal is a NORMAL result of an index query, not a tool
// failure: it surfaces here as Ok=false with the refusal text in Stderr and
// ExitCode=2, NOT as an mcp IsError envelope. The model reads Ok=false + the
// Stderr hint ("run `funpack build` to emit it") and self-corrects. Only a
// genuine spawn/resolve failure (no funpack binary, an unstartable child) is a
// tool error.
type WardenOutput struct {
	Ok       bool   `json:"ok" jsonschema:"true when the warden subcommand exited 0; false on a refusal (exit 2) or any non-zero exit — a refusal is a normal result, not a tool error"`
	Stdout   string `json:"stdout" jsonschema:"the subcommand's stdout: NDJSON rows or index-projection text, passed through verbatim"`
	Stderr   string `json:"stderr" jsonschema:"the subcommand's stderr; on a refusal (exit 2) this carries the index-missing/malformed reason"`
	ExitCode int    `json:"exit_code" jsonschema:"raw process exit status: 0 success, 2 index refusal, other non-zero for any other failure"`
}

// WardenDirInput is the input for the no-argument warden subcommands
// (holes/probes/debt/tags/pipeline): just the project directory whose committed
// index to query. funpack verbs read the §14 project tree at the process cwd, so
// Dir is how the tool points the warden at a specific project.
type WardenDirInput struct {
	Dir string `json:"dir" jsonschema:"project directory whose committed .funpack/index.ndjson to query; runs the warden subcommand with this as its working directory"`
}

// WardenFindInput is the input for warden_find: a project directory plus the
// declaration query. Query is the warden's positional substring filter — the name
// fragment to look up before writing a new declaration; an empty result means
// nothing to reuse.
type WardenFindInput struct {
	Dir   string `json:"dir" jsonschema:"project directory whose committed .funpack/index.ndjson to query"`
	Query string `json:"query" jsonschema:"declaration name substring to look up (the warden find positional filter); an empty result means nothing existing to reuse"`
}

// WardenGraphInput is the input for warden_graph: a project directory plus an
// optional node filter. An empty Node prints the whole dependency graph; a set
// Node restricts the projection to that node's edges (the warden graph optional
// positional).
type WardenGraphInput struct {
	Dir  string `json:"dir" jsonschema:"project directory whose committed .funpack/index.ndjson to query"`
	Node string `json:"node,omitempty" jsonschema:"optional node name to filter the graph to one node's edges; omit for the full dependency graph"`
}

// registerWardenTools wires one MCP tool per `funpack warden` subcommand. Each
// tool runs the subcommand as a one-shot child in the caller's Dir over the
// committed .funpack/index.ndjson and returns the verbatim outcome as a
// WardenOutput — NDJSON / projection text in Stdout, the exit code passed through.
//
// The binary is resolved per call (funpack.Resolve honors $FUNPACK_BIN then PATH),
// so the tool tracks whatever funpack the operator points at; a resolve or spawn
// failure is the only condition surfaced as a tool error. A non-zero exit — the
// index-refusal exit 2 included — is a normal result carried in WardenOutput.
func registerWardenTools(srv *mcp.Server, logger zerolog.Logger) {
	// The no-argument subcommands share one input/run shape: query the index in
	// Dir with no extra argv.
	type bareTool struct {
		name string
		sub  string
		desc string
	}
	bareTools := []bareTool{
		{"warden_holes", "holes", "List every typed hole in the project's committed funpack index."},
		{"warden_probes", "probes", "List every debug probe in the project's committed funpack index."},
		{"warden_debt", "debt", "List declarations tagged as debt in the project's committed funpack index."},
		{"warden_tags", "tags", "List the registered governance tags in the project's committed funpack index."},
		{"warden_pipeline", "pipeline", "Print the pipeline projection from the project's committed funpack index."},
	}
	for _, bt := range bareTools {
		bt := bt
		mcp.AddTool(srv, &mcp.Tool{
			Name:        bt.name,
			Description: bt.desc,
		}, func(ctx context.Context, _ *mcp.CallToolRequest, in WardenDirInput) (*mcp.CallToolResult, WardenOutput, error) {
			return runWarden(ctx, logger, in.Dir, bt.sub)
		})
	}

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "warden_find",
		Description: "Look up an existing declaration in the project's committed funpack index before writing a new one. Query is a name substring; an empty result means nothing to reuse.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in WardenFindInput) (*mcp.CallToolResult, WardenOutput, error) {
		if in.Query == "" {
			logger.Debug().Msg("warden_find empty query")
			res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategoryInvalidInput, "query must not be empty"))
			return res, WardenOutput{}, protoErr
		}
		return runWarden(ctx, logger, in.Dir, "find", in.Query)
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "warden_graph",
		Description: "Print the dependency graph from the project's committed funpack index, optionally filtered to one node's edges.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in WardenGraphInput) (*mcp.CallToolResult, WardenOutput, error) {
		args := []string{"graph"}
		if in.Node != "" {
			args = append(args, in.Node)
		}
		return runWarden(ctx, logger, in.Dir, args...)
	})
}

// runWarden resolves the funpack binary and runs `funpack warden <args...>` in
// dir, mapping the structured Result onto a WardenOutput. A resolve or spawn
// failure is a tool error (CategoryResolver / CategoryExec); every captured exit
// — zero or non-zero, the index-refusal exit 2 included — is a normal WardenOutput
// with Ok set from the exit status. The first arg is the warden subcommand.
func runWarden(ctx context.Context, logger zerolog.Logger, dir string, args ...string) (*mcp.CallToolResult, WardenOutput, error) {
	bin, err := funpack.Resolve()
	if err != nil {
		logger.Debug().Err(err).Strs("args", args).Msg("warden resolve failed")
		res, protoErr := mcperr.ToolError(err)
		return res, WardenOutput{}, protoErr
	}

	// `funpack warden <sub> [args]` — prepend the warden verb to the subcommand argv.
	wardenArgs := append([]string{"warden"}, args...)
	result, err := funpackexec.RunInDir(ctx, dir, bin, wardenArgs...)
	if err != nil {
		// A genuine spawn/IO failure (binary unstartable, context cancelled): a tool
		// error the model cannot treat as an index answer.
		logger.Debug().Err(err).Str("dir", dir).Strs("args", wardenArgs).Msg("warden exec failed")
		res, protoErr := mcperr.ToolError(err)
		return res, WardenOutput{}, protoErr
	}

	logger.Debug().
		Str("dir", dir).
		Strs("args", wardenArgs).
		Int("exit_code", result.ExitCode).
		Msg("warden query")
	return nil, WardenOutput{
		Ok:       result.ExitCode == 0,
		Stdout:   result.Stdout,
		Stderr:   result.Stderr,
		ExitCode: result.ExitCode,
	}, nil
}
