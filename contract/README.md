# funpack↔MCP API contract

`funpack-api.json` is the single source of truth for the funpack↔MCP boundary — the shape of
every MCP tool and parameter. `funpack mcp gen-contract` projects it into the generated Odin
file `funpack/api_contract.gen.odin`, which the compiler subtree consumes.

## Ownership: a shared seam, co-owned per task

This file is a **shared cross-team seam**, not any one team's property. devtools owns the MCP
tool surface the contract describes; funpack owns the compiler-side shape the generated file
feeds. No team's *standing* write glob claims `funpack-api.json` or `api_contract.gen.odin` —
giving one side unilateral write to a boundary both depend on defeats the seam.

A change that crosses this boundary:

1. Edits `contract/funpack-api.json` (the source) and regenerates
   `funpack/api_contract.gen.odin` via `funpack mcp gen-contract`. The generated file is a
   build artifact — never hand-edited.
2. Is gated by `test_contract_gen_pin_byte_match` (`cmd/funpack/mcp_contract_gen_test.odin`): a
   JSON edit without a matching regen fails `task test`. Consistency is mechanical, not an
   honor-system.
3. Is made by a team agent under a **per-task** `--bounds` widening that adds these two files
   for that task — the standing team glob stays narrow.
4. Owes a contract-pin regen, **not** a docs-corpus regen: neither file is corpus-embedded (the
   corpus embed scope is `plugins/funpack/`, `spec/`, `stdlib/engine/` only).

See decision `2026-06-24-funpack-mcp-contract-shared-seam-co-ownership`.
