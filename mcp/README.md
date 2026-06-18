# funpack-mcp

Model Context Protocol server for the funpack toolchain. A standalone Go module
(`github.com/mjmorales/funpack/mcp`) that exposes funpack to MCP-aware agents over
stdio. It is **not** linked into the Odin engine — it drives `funpack` as a child
process and over the §28 introspect protocol.

## Stack

- [cobra](https://github.com/spf13/cobra) — CLI surface (`serve`, `version`)
- [viper](https://github.com/spf13/viper) — config (flags → `FUNPACK_MCP_*` env → file → defaults)
- [zerolog](https://github.com/rs/zerolog) — structured logging, **stderr only**
- [go-sdk](https://github.com/modelcontextprotocol/go-sdk) — the official MCP SDK

> stdout carries the MCP stdio JSON-RPC stream. Nothing else — logs, prompts,
> diagnostics — may ever be written there. zerolog is pinned to stderr for this
> reason.

## Develop

```sh
task mcp:build   # → bin/funpack-mcp
task mcp:test
task mcp:lint
task mcp:run     # serve over stdio
```

## Tools

The full tool surface (one-shot verbs, §28 session tools, docs search) is
documented in `plugins/funpack/references/mcp-tools.md` — the agent-facing routing
table, kept in sync with `server.New`. A few notes that live with the code:

| Tool                | Note                                                                                                                                              |
|---------------------|---------------------------------------------------------------------------------------------------------------------------------------------------|
| `health`            | Liveness + build version (registration smoke test).                                                                                               |
| `inspect_draw_list` | One committed tick's deterministic §20 draw-list. Always serves headless — it IS the determinism-path render output, screenshot's sim-pure twin.   |
| `inspect_screenshot`| Captures a committed tick as a PNG the model can SEE. Crosses the render/present boundary, which only a funpack built with `FUNPACK_LIVE` serves. A binary without it refuses with a precise error directing the caller to `inspect_draw_list` (the headless substitute). The shipped funpack binary IS the `FUNPACK_LIVE` build, so screenshot serves even headless (SDL dummy video driver — no display needed). |
