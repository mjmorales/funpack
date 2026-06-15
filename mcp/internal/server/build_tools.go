package server

import (
	"context"

	"github.com/mjmorales/funpack/mcp/internal/funpack"
	"github.com/mjmorales/funpack/mcp/internal/funpackexec"
	"github.com/mjmorales/funpack/mcp/internal/mcperr"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/rs/zerolog"
)

// BuildInput drives `funpack build` against the project tree at Dir. Release
// selects the optimized, shippable build via --release; omit it for a fast dev
// build. Dir is required: funpack has no project-path flag, so the tool points
// funpack at a project by running it with that working directory.
type BuildInput struct {
	Dir     string `json:"dir" jsonschema:"absolute path to the funpack project tree to build (the funpack verb operates on the project at this working directory)"`
	Release bool   `json:"release,omitempty" jsonschema:"build the optimized shippable artifact (passes --release); omit for a fast dev build"`
}

// CheckInput drives `funpack check` against the project tree at Dir — the
// type/static-analysis pass. Release runs the check against the release build
// configuration via --release.
type CheckInput struct {
	Dir     string `json:"dir" jsonschema:"absolute path to the funpack project tree to check (the funpack verb operates on the project at this working directory)"`
	Release bool   `json:"release,omitempty" jsonschema:"check against the release build configuration (passes --release)"`
}

// FmtInput drives `funpack fmt` against the project tree at Dir. Check makes it
// verdict-only — fmt reports whether the tree is formatted (non-zero exit on
// drift) without rewriting files, via --check.
type FmtInput struct {
	Dir   string `json:"dir" jsonschema:"absolute path to the funpack project tree to format (the funpack verb operates on the project at this working directory)"`
	Check bool   `json:"check,omitempty" jsonschema:"verdict-only mode (passes --check): report whether the tree is formatted via the exit code without rewriting files"`
}

// CommandOutput is the structured result every build-family tool returns. It is
// funpack's exit code and captured streams, surfaced verbatim so the agent reads
// funpack's own diagnostics passthrough and branches on the code. Ok is the
// convenience predicate ExitCode == 0; a non-zero exit is a NORMAL result with
// Ok false, never a tool error — only a missing project dir or a resolve/spawn
// failure is a tool error.
type CommandOutput struct {
	ExitCode int    `json:"exit_code" jsonschema:"funpack process exit status; zero on success, non-zero when funpack signals a domain outcome (a failing check, formatting drift)"`
	Stdout   string `json:"stdout" jsonschema:"funpack stdout — its diagnostics and build output, passed through verbatim"`
	Stderr   string `json:"stderr" jsonschema:"funpack stderr — its error and warning output, passed through verbatim"`
	Ok       bool   `json:"ok" jsonschema:"true when ExitCode is zero; the at-a-glance pass/fail the agent branches on"`
}

// registerBuildTools wires the four one-shot build-family verbs onto srv: build,
// export, check, and fmt. Each resolves the funpack binary, runs the verb in the
// caller-supplied project directory via funpackexec.RunInDir, and returns funpack's
// exit code and captured streams as a CommandOutput. export is a thin alias for
// `build --release` — the shippable build — so an agent need not know the release
// flag to ship.
func registerBuildTools(srv *mcp.Server, logger zerolog.Logger) {
	mcp.AddTool(srv, &mcp.Tool{
		Name:        "build",
		Description: "Build the funpack project at the given directory (a fast dev build by default; pass release for the optimized artifact).",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in BuildInput) (*mcp.CallToolResult, CommandOutput, error) {
		args := []string{"build"}
		if in.Release {
			args = append(args, "--release")
		}
		return runBuildVerb(ctx, logger, "build", in.Dir, args)
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "export",
		Description: "Export the shippable funpack artifact for the project at the given directory (the optimized release build).",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in BuildInput) (*mcp.CallToolResult, CommandOutput, error) {
		// export is the shippable build: a thin alias for `build --release`,
		// regardless of the Release flag (the artifact is release by definition).
		return runBuildVerb(ctx, logger, "export", in.Dir, []string{"build", "--release"})
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "check",
		Description: "Type-check and statically analyze the funpack project at the given directory without producing an artifact.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in CheckInput) (*mcp.CallToolResult, CommandOutput, error) {
		args := []string{"check"}
		if in.Release {
			args = append(args, "--release")
		}
		return runBuildVerb(ctx, logger, "check", in.Dir, args)
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "fmt",
		Description: "Format the funpack project at the given directory (or, in check mode, report whether it is already formatted).",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in FmtInput) (*mcp.CallToolResult, CommandOutput, error) {
		args := []string{"fmt"}
		if in.Check {
			args = append(args, "--check")
		}
		return runBuildVerb(ctx, logger, "fmt", in.Dir, args)
	})
}

// runBuildVerb is the shared body of every build-family tool: validate the
// project dir, resolve the funpack binary, run argv in dir, and map the outcome.
// A missing dir or a resolve/spawn failure is a tool error the agent reads and
// self-corrects from; a non-zero funpack exit is a NORMAL CommandOutput with Ok
// false so the agent branches on funpack's own diagnostics.
func runBuildVerb(ctx context.Context, logger zerolog.Logger, verb, dir string, args []string) (*mcp.CallToolResult, CommandOutput, error) {
	if dir == "" {
		res, protoErr := mcperr.ToolError(mcperr.New(mcperr.CategoryInvalidInput, verb+": dir is required (path to the funpack project tree)"))
		return res, CommandOutput{}, protoErr
	}

	bin, err := funpack.Resolve()
	if err != nil {
		logger.Debug().Str("verb", verb).Err(err).Msg("funpack resolve failed")
		res, protoErr := mcperr.ToolError(err)
		return res, CommandOutput{}, protoErr
	}

	out, err := funpackexec.RunInDir(ctx, dir, bin, args...)
	if err != nil {
		logger.Debug().Str("verb", verb).Str("dir", dir).Err(err).Msg("funpack exec failed")
		res, protoErr := mcperr.ToolError(err)
		return res, CommandOutput{}, protoErr
	}

	logger.Debug().Str("verb", verb).Str("dir", dir).Int("exit_code", out.ExitCode).Msg("funpack verb complete")
	return nil, CommandOutput{
		ExitCode: out.ExitCode,
		Stdout:   out.Stdout,
		Stderr:   out.Stderr,
		Ok:       out.ExitCode == 0,
	}, nil
}
