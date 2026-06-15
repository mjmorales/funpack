---
schema_version: 1
provenance:
  created_by: null
  created_at: 2026-06-04T11:48:26.453Z
  last_modified_by: null
  last_modified_at: 2026-06-04T11:48:26.453Z
---

# Team

## Roster

Functional seats modeled on engine/language-product org charts (Unity scripting team,
Epic engine/tools split, Godot area maintainers, JetBrains-style language team). Every
seat except the Studio Director is filled by interchangeable agents dispatched under
prove governance.

| Name | Role | Responsibilities |
| ---- | ---- | ---------------- |
| Manuel Morales | Studio Director / Operator | Direction, spec authorship (in-repo `spec/`), architecture decisions, final review gate, milestone calls |
| language-lead-seat | Language Lead | LL(1) grammar ownership, spec conformance, divergence filing in `spec/` |
| frontend-seat | Compiler Frontend Engineer | Lexer, parser, AST, formatter |
| semantics-seat | Compiler Semantics Engineer | Typechecker, structural quality gates, fix-criteria diagnostics |
| backend-seat | Compiler Backend Engineer | Artifact emission, Index Contract (schema-versioned, exact-match NDJSON), bit-identical determinism |
| runtime-seat | Runtime Engineer | Artifact execution, fixed-point simulation (never float), `engine.*` stdlib surface |
| tools-seat | Tools & Pipeline Engineer | Dependency resolution, asset pipeline, test runner |
| governance-seat | Governance Engineer (`funpack warden`) | The `funpack warden` pure sub-toolchain — index-query surface (`find`/`holes`/`debt`/`graph`) — and the governance ethos the directives and gates enforce; never writes source |
| qa-seat | QA / Acceptance Engineer | Nine golden-example acceptance suite, conformance and determinism harness |
| producer-seat | Producer / TPM | Backlog, dep-graph, milestone tracking via prove scrum |
| docs-seat | Tech Writer / DevRel | Docs, diagnostics wording, example walkthroughs |
