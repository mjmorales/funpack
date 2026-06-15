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

| Tool     | Purpose                                            |
|----------|----------------------------------------------------|
| `health` | Liveness + build version (registration smoke test) |

The operational surface (one-shot verbs, §28 session tools, docs search) lands
under the `funpack-mcp` milestone.
