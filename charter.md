---
schema_version: 1
provenance:
  created_by: null
  created_at: 2026-06-04T11:48:26.453Z
  last_modified_by: null
  last_modified_at: 2026-06-04T11:48:26.453Z
operator_of_record: ct-manuel-morales-1b03670f-5de8-4cd6-ba5b-a6e5d94f61d6
---

# Project Charter

## Vision

A world where game development is agent-first: LLM agents author, verify, and ship game
code as first-class participants. Programming with LLMs is fun — because the language is
LL(1)-parseable, builds are bit-identical by construction, and the compiler is a quality
gate whose diagnostics make agent write → check → fix loops converge.

## Mission

Build the toolchain the [funpack-spec](https://github.com/mjmorales/funpack-spec) repo
defines, for LLM agents and the operators who direct them: `funpack`, the pure
source → artifact compiler emitting the versioned Index Contract; `warden`, the impure
governance binary owning the task DB, leases, and swarm dispatch; and the runtime that
executes the artifact. The spec repo is the doctrine — this repo is the machine that
satisfies it, measured against the spec, the nine golden examples, and the stdlib engine
surface.

## Outcome Bet

All nine golden reference projects (`pong`, `snake`, `hunt`, `yard`, `arena`, `krognid`,
`hud`, `assets`, `numerics`) compile and deterministically run — same inputs + seed
produce bit-identical simulation on every machine. A surface area is done when the
examples that exercise it pass; funpack does not grammar-include what it cannot run.
