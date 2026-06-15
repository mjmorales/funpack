# 15 — Modules & visibility

A module's name **is its path**. Nothing declares it — there is **no `module` keyword**. A `.fun`
file's module is its location under the source root: directory segments dotted, filename as the leaf.
This is the same derive-don't-declare discipline as realm, pipeline wiring, and entrypoint selection
— the filesystem is the single source of truth, and a redundant `module X` line that could drift from
its path does not exist to get wrong.

---

## 1. The rule

| File (under the source root) | Module |
|---|---|
| `src/pong.fun` | `pong` |
| `src/combat/melee.fun` | `combat.melee` |
| `src/combat.fun` | `combat` |
| `stdlib/engine/math.fun` | `engine.math` |

- **A directory is a namespace.** `src/combat/` is the `combat` namespace.
- **An optional sibling `<name>.fun` carries that namespace's own declarations** (`src/combat.fun`
  *is* module `combat`; `src/combat/melee.fun` is `combat.melee`). The two coexist (Rust-2018 style);
  there is **no `mod.fun` index file**.
- **A directory with no sibling file is a pure namespace** (a prefix only; `import engine.{…}` names
  nothing — there is no `engine.fun`).

## 2. The module doc

The module is implicit, so its documentation attaches **by position**: a `@doc` that is the first
item in a file — before any `import` or declaration — documents the file's module (a Rust `//!` /
Python module-docstring, in directive grammar). A pure-namespace directory has no module doc.

## 3. Imports are absolute

Rooted at the namespace root, always. There are **no relative imports** — no `self`/`super`/`../`
(a relative import means a different module in different files, the exact ambiguity P-roots forbid).

```
import engine.math                          // whole module
import engine.math.max                       // one item
import engine.math.{Fixed, Vec2, clamp}      // selected items
```

`.fcfg`'s `use` resolves the same paths ([`14`](14-project-config.md)).

## 4. Visibility — two boundaries

| Boundary | Rule |
|---|---|
| **within a project** (module → sibling module) | public-by-default, no markers |
| **across a package edge** (package → consumer/mod) | importable **iff `@expose`d**; the rest is package-private |

**Within a project**, every top-level declaration is importable. There is **no `pub` modifier** and
no private declarations. Encapsulation is a property of **module granularity** — put a helper you
don't want widely used in its own narrow module — not a per-declaration knob. One reason per root: P5
(a visibility modifier is a per-site knob); P7 (the reuse/duplication gate *wants* every helper
visible to the index, so a reimplementation is caught); P2 (one fewer concept). `funpack warden find`
noise from internal helpers is mitigated by `@gtag`/`@doc` ranking (an untagged, undoc'd helper ranks
low).

**Across a package edge**, a dependency exposes a deliberate API: an item is importable by a consumer
only if marked `@expose` ([`05`](05-directives.md)), and the exposed set generates the package's
`<name>.api.gen.fun` contract. This is the one place a visibility marker appears — the external
contract is an irreducible design act with no universal answer, not a knob — and the same `@expose`
surface is what a mod is confined to. See [`30`](30-packages.md) §6 and [`27`](27-modding.md).

## 5. The package boundary

The **project name is not a namespace prefix.** Within a project, modules root at the source root
unprefixed (`pong`, `combat.melee`). The project name becomes a root namespace **only across the
package boundary** — an external project `foo` pulled in via the curated-package escape hatch has
modules `foo.*` (the Rust crate-name rule). The **stdlib is the built-in package**, occupying the
reserved root **`engine`**; a user `src/engine/` is a name-collision **compile error** (reserved
roots are unshadowable). This is what earns `project.fcfg`'s `name` its keep.

## 6. Generated seams

A generated seam's module is its **source filename**, placed in the **root namespace** — `ui/hud.fui`
generates module `hud`, `models/krognid.fpm` generates module `krognid`. `.gen.fun` is a
compiler-owned filename marker, **not** a namespace segment, so a seam imports as if hand-authored —
invisible at the import site. Two sources producing the **same module name is a compile error**.

## 7. Reserved roots

`engine` is the **single** reserved root namespace — the built-in stdlib package. The reserved set is
**closed and compiler-fixed** (there is no extensible registry); a user module path under `engine.*`
is a **compile error** ([`14`](14-project-config.md)). A module's leading `@doc` is permitted on the
public surface.
