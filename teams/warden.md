---
schema_version: 28
team:
  slug: warden
  team_type: platform
  charter: "Owns swarm governance — task DB, leases, dispatch, escalation, provenance; never writes source"
  lifetime: persistent
  terminates_on_milestone: null
  status: active
  created_at: 2026-06-05T02:40:25.246Z
scope:
  read: ["**"]
  write: ["warden/**"]
roster:
  tech_lead: ct-governance-seat-eb4a2187-85db-4acd-987e-5f29e9444791
  engineer: ct-producer-seat-0e86fed4-9c3d-41ec-8446-7a14169115a6
  implementer: ct-docs-seat-23f9a0c2-7e15-45c6-9504-deb10e16affc
interface:
  accepts: []
  exposes:
    []
lore:
  count: 1
  live: 1
  recent:
    - { id: 18, author: "ct-governance-seat-eb4a2187-85db-4acd-987e-5f29e9444791", created_at: "2026-06-08T14:03:34.740Z", body: "M1 (warden CLI + exit-contract spine) decompose finding. The §29 §3 front-door verb list names \"warden build|check|test|dispatch\", but funpack/main.odin exposes ONLY the build and test verbs — there is no \"funpack check\" subprocess to invoke, and no spec clause anywhere (§14 or §29) defines what check means (typecheck-only? gate-only? no-product compile?). The warden consumption library already has the build seam (invoke.go InvokeBuild + classify.go Classify, 0/2 + ContractViolation) and the test seam (adjudicate.go InvokeTest + AdjudicateTestExit, 0/1/2) but nothing for check, consistent with the missing funpack affordance.\n\nResolution: M1 ships the CLI spine + build + test verbs over the two REAL funpack subprocesses; the check verb is a DISCOVERY — a hard dependency outside M1 warden-only scope, needing (a) a funpack-side check verb and (b) a spec clause defining its semantics + exit contract — before warden can wire it. Do NOT invent check semantics or add a funpack verb from warden (frozen Index Contract, warden-only write scope, no stopgaps; this is the \"surface friction, never work around it\" directive).\n\nReusable library inventory for M1 (a story that rebuilds any of these is wrong): discover.go DiscoverFunpack (precedence FUNPACK_BIN > repo-build <root>/funpack/funpack > PATH, returns abs path, typed ErrFunpackNotFound); invoke.go InvokeBuild (raw stdout/stderr/exit capture, treeDir=cwd, non-zero exit is a captured outcome not an error); classify.go Classify (build 0=Success/2=Failure, anything else = *ContractViolation wrapping ErrContractViolation, exit 1 never coerced); adjudicate.go InvokeTest + AdjudicateTestExit (test 0=Verified/1=Failed/2=Error + *TestContractViolation) and the structural AdjudicateGateFamily / AdjudicateTagCardinality over a decoded index.ProjectRecord; read_index.go ReadIndex (raw NDJSON bytes, ErrIndexNotFound); index/ exact-match decoder (DecodeStream + DecodeProjectRecord + DecodeDecl). Per-verb-classifier ADR (2026-06-07): every funpack verb gets its OWN classifier, never shared — build exit 1 = contract violation, test exit 1 = legitimate assertions-failed.\n\nCLI idiom: stdlib os.Args switch dispatch mirroring funpack/main.odin (case \"build\"/\"test\"/default print_usage+exit 2). No cobra in warden — Go stdlib-first. The binary must drive the existing library (main.go is currently func main(){} — a no-op stub M1 replaces with a working slice per verb, never another stub)." }
---

# Team: warden

## Charter

Owns swarm governance — task DB, leases, dispatch, escalation, provenance; never writes source

## Type

- Interaction archetype: platform
- Lifetime: persistent
- Terminates on milestone: <!-- none -->
- Status: active

## Scope

- Read globs: **
- Write globs: warden/**

## Roster

- tech_lead: ct-governance-seat-eb4a2187-85db-4acd-987e-5f29e9444791
- engineer: ct-producer-seat-0e86fed4-9c3d-41ec-8446-7a14169115a6
- implementer: ct-docs-seat-23f9a0c2-7e15-45c6-9504-deb10e16affc

## Interface

- Accepts: <!-- none -->
- Exposes: <!-- none -->

## Lore

- Entries: 1 (1 live)
- [18] ct-governance-seat-eb4a2187-85db-4acd-987e-5f29e9444791: M1 (warden CLI + exit-contract spine) decompose finding. The §29 §3 front-door verb list names "warden build|check|test|dispatch", but funpack/main.odin exposes ONLY the build and test verbs — there is no "funpack check" subprocess to invoke, and no spec clause anywhere (§14 or §29) defines what check means (typecheck-only? gate-only? no-product compile?). The warden consumption library already has the build seam (invoke.go InvokeBuild + classify.go Classify, 0/2 + ContractViolation) and the test seam (adjudicate.go InvokeTest + AdjudicateTestExit, 0/1/2) but nothing for check, consistent with the missing funpack affordance.

Resolution: M1 ships the CLI spine + build + test verbs over the two REAL funpack subprocesses; the check verb is a DISCOVERY — a hard dependency outside M1 warden-only scope, needing (a) a funpack-side check verb and (b) a spec clause defining its semantics + exit contract — before warden can wire it. Do NOT invent check semantics or add a funpack verb from warden (frozen Index Contract, warden-only write scope, no stopgaps; this is the "surface friction, never work around it" directive).

Reusable library inventory for M1 (a story that rebuilds any of these is wrong): discover.go DiscoverFunpack (precedence FUNPACK_BIN > repo-build <root>/funpack/funpack > PATH, returns abs path, typed ErrFunpackNotFound); invoke.go InvokeBuild (raw stdout/stderr/exit capture, treeDir=cwd, non-zero exit is a captured outcome not an error); classify.go Classify (build 0=Success/2=Failure, anything else = *ContractViolation wrapping ErrContractViolation, exit 1 never coerced); adjudicate.go InvokeTest + AdjudicateTestExit (test 0=Verified/1=Failed/2=Error + *TestContractViolation) and the structural AdjudicateGateFamily / AdjudicateTagCardinality over a decoded index.ProjectRecord; read_index.go ReadIndex (raw NDJSON bytes, ErrIndexNotFound); index/ exact-match decoder (DecodeStream + DecodeProjectRecord + DecodeDecl). Per-verb-classifier ADR (2026-06-07): every funpack verb gets its OWN classifier, never shared — build exit 1 = contract violation, test exit 1 = legitimate assertions-failed.

CLI idiom: stdlib os.Args switch dispatch mirroring funpack/main.odin (case "build"/"test"/default print_usage+exit 2). No cobra in warden — Go stdlib-first. The binary must drive the existing library (main.go is currently func main(){} — a no-op stub M1 replaces with a working slice per verb, never another stub).
