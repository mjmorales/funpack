# 30 — Packages & dependencies

funpack is batteries-included: the standard library *is* the engine, and the vast majority of
games never leave `engine.*`. Packages are the **barebones escape hatch** for domain-specific logic
the engine does not carry — a hex-grid library, a card-rules engine, studio-shared code. The system
is deliberately the opposite of npm/cargo: no resolver, no version ranges, no transitive sprawl, no
install scripts.

The design rests on one split.

---

## 1. Capability-safety vs. provenance-trust

Every supply-chain *catastrophe* — exfiltrate secrets, drop a backdoor, mine crypto, own the host —
requires **ambient capability**: IO, network, filesystem, a clock, or arbitrary code at
install/build time. funpack has none to grant:

- **No install or build scripts exist.** A package is `.fun` source compiled by the pure `funpack`
  compiler. There is no `postinstall`, no `build.rs`; that attack class is *unrepresentable*.
- **`extern` is gated off** ([`26`](26-stdlib.md)) — a package cannot summon native code.
- **Effects are data; purity is the default** ([`04`](04-effects.md)). A package function that
  touches the world must return a command type or take an engine resource — visible in its
  signature. With no ambient IO in scope, a package has the **same capability ceiling as your own
  code**.

So a malicious package's worst case is **returning wrong values** — a logic bug caught by your tests
and types — never host takeover. This splits the problem:

- **Capability-safety is uniform and by construction.** Every dependency, from any source, is
  bounded by the effect system, identically. Closed for everyone.
- **Provenance-trust is graduated and human-sized.** All that remains is "do I trust this *logic*" —
  small, reviewable, never a machine-takeover question.

npm/cargo fight on the capability axis because they cannot close it. funpack closes it, so the
dependency system serves only provenance — which is why it is light.

---

## 2. The star graph — depth-1, always

**A package depends only on `engine`. It may not depend on another package.** A package importing a
package is a compile error. Your game's dependency graph is a star:

```
game → { engine, + exactly the packages you declared }
```

Consequences, all of them payoffs:

- **No version solving, no resolver, no diamonds.** There is no SAT problem because there is no
  graph to solve.
- **"Transitive dependency" does not exist.** Every package hash in your build was chosen by a
  human who can audit it. There are no packages you did not pick.
- **Composition belongs in the consuming game.** The rare "library builds on library" case resolves
  by composing them in *your* code, where the context lives — or by writing the package generically
  over `engine.*`.
- **A dep popular enough to be widely shared is a stdlib candidate.** The star graph turns
  "everyone depends on X" into pressure to enrich the engine — the correct outcome for a
  batteries-included language.

This is the literal reading of the axiom's "no transitive-dependency sprawl" ([`01`](01-axioms.md)).

---

## 3. Four sources, one ceiling

A dependency is named in `funpack_configs/deps.fcfg`. There are four provenance sources; they are
**capability-identical** and differ only in who vouches for the logic:

```
use hexgrid  version "0.4"  hash "sha256:1c77…"          // 1. curated registry
use shared   path    "../studio-shared"                  // 2. local path
use steering url "https://…/steering-2.0.tar"  hash "sha256:9f3a…"   // 3. url
//                                                          (4. stdlib — engine.*, no decl needed)
```

| Source | Vouched by | Hash | Use for |
|---|---|---|---|
| `stdlib` | the engine | — | the default; most games stay here |
| `path` | you | — | your own local/shared code (studio libraries) |
| `registry` | curation + you | required | a published domain library |
| `url` | you | required | anything not in the registry — the decentralization valve |

`deps.fcfg` is **optional**; a stdlib-only game has none. A `path` dep is a real package (its own
tree, its own exposed API). If you want zero-ceremony sharing, that is not a package — it is more
modules in your own `src/` ([`15`](15-modules.md)).

---

## 4. Pins, vendoring, hermetic builds

- **Content-hash pins, no version ranges.** A registry/url dep is pinned to an exact `hash`. The
  human-friendly `version` rides alongside for discovery; a label/hash mismatch is a compile error.
  funpack **never auto-upgrades** — ranges are *how* you get pulled into a compromised release, so
  there are none. The pin is the lockfile; no manifest-vs-lock drift.
- **Vendored by default.** Because a package is pure, hash-verified source, the dependency's source
  is fetched into `packages/<name>/`, **committed**, and reviewed in PRs — no opaque `node_modules`.
  The hash verifies the vendored tree every build, catching local tampering too.
- **Hermetic builds.** No network at build time → no registry outage, no mid-build poisoning,
  reproducible offline. The registry is discovery + initial fetch + curation; after `funpack add`,
  you own the source.
- **Generated seams are not vendored.** A package's `gen/` ([`14`](14-project-config.md)) is rebuilt
  deterministically in the consumer's build. Vendor + hash + hermetic + deterministic bake ⇒
  **bit-identical package builds**.

---

## 5. Updates are reviewed diffs; yanks are advisory

- **`funpack update <name>`** shows the **source diff against your vendored copy** before changing
  the hash. Every change to dependency code is a human-reviewed diff — you cannot be silently
  upgraded into a compromised release. This is the system's single biggest practical safety win.
- **A yanked/flagged hash warns; it never breaks your build.** Because you vendored, a compromised
  upstream is a prompt to `update`, not a broken build (contrast a registry yank taking down the
  world).

Two attack classes are **structurally impossible**, not mitigated:

- **Dependency confusion** — private deps are `path` deps; there is no name resolution that could
  prefer a public package, and no public/private split to confuse.
- **Typosquatting** — the single curated registry rejects squat names, and a name typo cannot match
  your intended *hash*.

---

## 6. Public vs. private — `@expose` at the package edge

A package's public API and a game's mod API are the same concept: the **external contract**. funpack
has one visibility primitive, `@expose` ([`05`](05-directives.md), [`27`](27-modding.md)), and two
sharply-split boundaries:

| Boundary | Rule |
|---|---|
| **within a project** (module → sibling module) | public-by-default, no markers ([`15`](15-modules.md) §3) |
| **across a package edge** (package → consumer) | importable **iff `@expose`d**; everything else is package-private |

```funpack
// packages/hexgrid/src/layout.fun
@doc("Axial→pixel for a hex of the given size. The package's public API.")
@expose
fn axial_to_pixel(cell: Hex, size: Fixed) -> Vec2 { … }

@doc("Internal rounding helper — not part of the contract.")
fn cube_round(x: Fixed, y: Fixed, z: Fixed) -> Hex { … }   // package-private: no @expose
```

```funpack
import hexgrid.layout.{axial_to_pixel}   // ok
import hexgrid.layout.{cube_round}        // compile error: cube_round is package-private
```

This is **contract-as-declaration, not visibility-as-knob.** "What is my package's public API" has
no universal right answer — it is an irreducible design act, the same category as the entrypoint and
realm facts ([`14`](14-project-config.md), [`25`](25-netcode.md)), so it is permitted under the same
reasoning that the no-knobs rule ([`01`](01-axioms.md) §P5) bans *configuration*. There is exactly
one boundary, so exactly one marker — no `pub(crate)`/`pub(super)` granularity zoo. A game with no
packages and no mods writes zero `@expose`.

The exposed surface generates **`<name>.api.gen.fun`** — authored inline via `@expose`, the seam
generated, never hand-maintained, so the API cannot drift from the manifest ("generate the seam,
never maintain it"). It is the same contract-as-coupling motif as the index, netcode, and modapi
seams ([`29`](29-architecture-governance.md)).

**One marker, two importer modes.** `@expose` declares the surface; the *importer's role* decides
confinement:

- A **package consumer** imports the exposed surface as a **peer** — full capability ceiling, calls
  *into* the library.
- A **mod** imports the same exposed surface but is **confined and sandboxed** — less trusted than
  your code, bounded *to* the contract ([`27`](27-modding.md)).

`extern` exposes natives downward to funpack; `@expose` exposes a contract upward, to packages and
mods alike.

---

## 7. A package is a project without an entrypoint

The structural definition: a game **runs** (has `funpack_configs/entrypoints.fcfg`,
[`14`](14-project-config.md)); a package is **imported** (has none). A package is otherwise a full
funpack project tree — `src/`, its own `funpack_configs/{project,tags}.fcfg`, and the full authoring
surface (`.fpm`, `.flvl`, `.fui`, `.manifest`) whose seams bake deterministically in the consumer's
build. The package name is its root namespace and joins `engine` as a **reserved root**: a local
`src/hexgrid.fun` shadowing the `hexgrid` dependency is a compile error ([`15`](15-modules.md)).

- The dependency's `.fun` is compiled through **your** pipeline — the same AX6 quality gates, effect
  closure, and exhaustiveness checks as your own code ([`01`](01-axioms.md) §P5). No second-class
  trust tier, no opaque binary.
- A package's `@gtag` tags are **package-local** — queryable, but they do not pollute your project's
  tag registry ([`08`](08-state.md)).
- **Binary assets** (PNG, audio) are the sole non-source-auditable element. They are content-hashed
  for integrity and are what registry curation scrutinizes hardest.

`funpack build` on a package emits the **Index Contract only**: with no entrypoint there is no
runtime artifact to select, so `.funpack/index.ndjson` ([`29`](29-architecture-governance.md) §2) is
the build's single product. The all-or-nothing write contract ([`14`](14-project-config.md)) is
per-project-kind — a game writes both products or none; a package writes its index or nothing. Exit
codes are unchanged: `0` on a clean index, `2` on any compile or write failure, never `1`. The
`funpack warden` surface governs packages through the same index it reads for games — holes, todos,
and tags of an imported
dependency are first-class governance data.

---

## 8. Open / provisional

(none)
