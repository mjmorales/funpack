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
  write: ["mcp/**", "plugins/funpack/**"]
roster:
  tech_lead: ct-devtools-lead-seat-00df5019-702d-4cb1-bc21-00939e3bb399
  engineer: ct-mcp-seat-f05a5819-b4e2-4f76-9b60-445f40870bb8
  implementer: ct-docs-tooling-seat-cbb7d509-c96b-4b84-b3b4-fdd3774b16c7
interface:
  accepts: []
  exposes:
    []
lore:
  count: 2
  live: 1
  recent:
    - { id: 01KVWZ864MW4W9TE5CMFKJRNNJ, author: "ct-devtools-lead-seat-00df5019-702d-4cb1-bc21-00939e3bb399", created_at: "2026-06-24T14:06:24.404Z", body: "The MCP introspection surface (cmd/funpack/mcp_tools_observe_time.odin, mcp_tools_control.odin, mcp_tools_session.odin) is a THIN, TRUTHFUL lift over the runtime's section-28 session: each tool marshals MCP args into a section-28 request line, folds through mcp_session_registry_request on the session arena, and lifts the section-28 result VERBATIM. Proven across the four colony-sim friction fixes (ADR 2026-06-24-mcp-introspection-live-simulation-scope): when the runtime engine half lands a behavior (R2 writable-branch forward-fold, R4 cursor-anchored implicit fork, the seedless-startup fold, the uses_rng status field), the surface AUTOMATICALLY exposes it because the dispatch lifts verbatim. The only surface work is (a) reading a NEW status field the enricher needs (Task 2 116a1681: Obs_Precondition gained uses_rng so the empty-inspect diagnostic stops blaming a missing seed for a no-RNG game) and (b) threading a NEW tool ARG (Task 1 9771c0f4: replay_log on session_start, which the runtime opener + registry already accepted end-to-end; only sess_start hardcoded empty replay). Before assuming a surface bug, repro against the runtime fixture (runtime/testdata/seedless_startup_spawn.artifact carries a march behavior so forward-fold is observable) and diff the section-28 envelope: if the runtime already returns the right thing the task is VERIFY+deliberate-spec, not a code change (Tasks 3 6e7bb2c4 and 4 c8ce3627 were both VERIFY). CROSS-FAMILY TEST PATTERN: a sequence spanning dispatch families (observe time_*/inspect_* + control control_*) must be driven through mcp_handle_tools_call (the production chain); the per-family obs_/ctrl_/sess_dispatch_tool harnesses only route their own family, so add a file-private chain helper (obs_chain_call/ctrl_chain_call). CONTRACT REGEN: a new tool arg is a contract/funpack-api.json edit + 'funpack mcp gen-contract' regen of funpack/api_contract.gen.odin, gated by test_contract_gen_pin_byte_match (NOT docs-regen: contract/ and funpack/ are not corpus-embedded trees, only plugins/funpack, spec, stdlib/engine are)." }
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
- Write globs: mcp/**, plugins/funpack/**

## Roster

- tech_lead: ct-devtools-lead-seat-00df5019-702d-4cb1-bc21-00939e3bb399
- engineer: ct-mcp-seat-f05a5819-b4e2-4f76-9b60-445f40870bb8
- implementer: ct-docs-tooling-seat-cbb7d509-c96b-4b84-b3b4-fdd3774b16c7

## Interface

- Accepts: <!-- none -->
- Exposes: <!-- none -->

## Lore

- Entries: 2 (1 live)
- [01KVWZ864MW4W9TE5CMFKJRNNJ] ct-devtools-lead-seat-00df5019-702d-4cb1-bc21-00939e3bb399: The MCP introspection surface (cmd/funpack/mcp_tools_observe_time.odin, mcp_tools_control.odin, mcp_tools_session.odin) is a THIN, TRUTHFUL lift over the runtime's section-28 session: each tool marshals MCP args into a section-28 request line, folds through mcp_session_registry_request on the session arena, and lifts the section-28 result VERBATIM. Proven across the four colony-sim friction fixes (ADR 2026-06-24-mcp-introspection-live-simulation-scope): when the runtime engine half lands a behavior (R2 writable-branch forward-fold, R4 cursor-anchored implicit fork, the seedless-startup fold, the uses_rng status field), the surface AUTOMATICALLY exposes it because the dispatch lifts verbatim. The only surface work is (a) reading a NEW status field the enricher needs (Task 2 116a1681: Obs_Precondition gained uses_rng so the empty-inspect diagnostic stops blaming a missing seed for a no-RNG game) and (b) threading a NEW tool ARG (Task 1 9771c0f4: replay_log on session_start, which the runtime opener + registry already accepted end-to-end; only sess_start hardcoded empty replay). Before assuming a surface bug, repro against the runtime fixture (runtime/testdata/seedless_startup_spawn.artifact carries a march behavior so forward-fold is observable) and diff the section-28 envelope: if the runtime already returns the right thing the task is VERIFY+deliberate-spec, not a code change (Tasks 3 6e7bb2c4 and 4 c8ce3627 were both VERIFY). CROSS-FAMILY TEST PATTERN: a sequence spanning dispatch families (observe time_*/inspect_* + control control_*) must be driven through mcp_handle_tools_call (the production chain); the per-family obs_/ctrl_/sess_dispatch_tool harnesses only route their own family, so add a file-private chain helper (obs_chain_call/ctrl_chain_call). CONTRACT REGEN: a new tool arg is a contract/funpack-api.json edit + 'funpack mcp gen-contract' regen of funpack/api_contract.gen.odin, gated by test_contract_gen_pin_byte_match (NOT docs-regen: contract/ and funpack/ are not corpus-embedded trees, only plugins/funpack, spec, stdlib/engine are).
