---
schema_version: 2
team:
  slug: devtools
  team_type: platform
  charter: "Owns agent/operator dev tooling — the funpack MCP dev server, the funpack-tuned docs index, and the plugin skill surface; never writes engine source"
  lifetime: persistent
  terminates_on_milestone: null
  status: active
  created_at: 2026-06-15T12:01:34.468Z
scope:
  read: ["**"]
  write: ["mcp/**", "plugins/funpack/**", "cmd/funpack/mcp_*.odin", "cmd/funpack/cli_mcp*.odin", "cmd/funpack/mcp/**"]
roster:
  tech_lead: ct-devtools-lead-seat-00df5019-702d-4cb1-bc21-00939e3bb399
  engineer: ct-mcp-seat-f05a5819-b4e2-4f76-9b60-445f40870bb8
  implementer: ct-docs-tooling-seat-cbb7d509-c96b-4b84-b3b4-fdd3774b16c7
interface:
  accepts: []
  exposes:
    []
lore:
  count: 0
  live: 0
  recent:
    []
---

# Team: devtools

## Charter

Owns agent/operator dev tooling — the funpack MCP dev server, the funpack-tuned docs index, and the plugin skill surface; never writes engine source

## Type

- Interaction archetype: platform
- Lifetime: persistent
- Terminates on milestone: <!-- none -->
- Status: active

## Scope

- Read globs: **
- Write globs: mcp/**, plugins/funpack/**, cmd/funpack/mcp_*.odin, cmd/funpack/cli_mcp*.odin, cmd/funpack/mcp/** (the MCP server re-homed into the entry package per ADR mcp-folds-into-odin-binary — not engine source)

## Roster

- tech_lead: ct-devtools-lead-seat-00df5019-702d-4cb1-bc21-00939e3bb399
- engineer: ct-mcp-seat-f05a5819-b4e2-4f76-9b60-445f40870bb8
- implementer: ct-docs-tooling-seat-cbb7d509-c96b-4b84-b3b4-fdd3774b16c7

## Interface

- Accepts: <!-- none -->
- Exposes: <!-- none -->

## Lore

- Entries: 0 (0 live)
- <!-- no live Lore -->
