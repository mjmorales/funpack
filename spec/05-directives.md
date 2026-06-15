# 05 — Directives

Directives are **compiler-native** annotations that prefix a declaration (or, for `@stub`, stand in
body/expression position). They are **inert toward user logic**: they never expand into
user-authored code and never alter control flow — this holds the no-macro line ([`01`](01-axioms.md)
P2). They feed only the gates, the index, the build lifecycle, and the generated contracts. The
directive **category is closed**; individual directives are not user-definable. The formatter
normalizes their order and placement.

A directive may also prefix an **enum variant** (e.g. each `Draw` variant carries a `@doc`).

---

## 1. Documentation & indexing

### `@doc("…")`
Timeless documentation attached to a declaration. The compiler **rejects temporal tokens**
(`todo`, `now`, `was`, `previously`, `fix`, …) inside it — it states what a thing *is*, never what
happened to it ([`01`](01-axioms.md) P6). It is the sole documentation channel; free comments do not
exist in `.fun`.

### `@gtag("…", …)`
Semantic labels drawn from the project's **declared registry** (`funpack_configs/tags.fcfg`,
[`14`](14-project-config.md)). An unregistered tag is a **compile error**, so the namespace never
rots into synonyms. The compiler builds the queryable code index from these (the AX8/P7 self-index).

---

A declaration's **kind** (`Axis`, `Button`, `CollisionLayer`, `Num`) is **not** a directive — it is a
type-ascription on the declaration line (`enum Name: Kind`, `data Name: Num`), specified in the
declaration grammar ([`02`](02-language-core.md) §7, [`03`](03-data-model.md) §4). A kind is
type-constitutive — it changes the type's role at every use site — whereas the directives below are
uniformly **descriptive metadata**.

---

## 2. Self-anchoring (the P8 surface)

### `@stub(T)` / `@stub(T, fallback)`
A typed hole standing in body or expression position. Callers typecheck against `T`, so top-down
construction and dependency injection work by construction. Compiles in **dev**, is index-tracked,
and is a **compile error in release** — you cannot ship a hole.

The two-argument form carries a **fallback approximation**: a funpack expression that typechecks
against the hole's `T` in the declaration's own parameter scope and **evaluates in dev**, so the
game stays playable while the hole stands (`fn launch_speed(boost: Fixed) -> Fixed @stub(Fixed,
boost + 6.0)`). The fallback changes nothing about the hole's governance — it is index-tracked and
release-banned exactly like the bare form. A bare `@stub(T)` carries nothing to run: it is
typecheck-only, and a dev execution that reaches it **fails closed** (a defined no-value outcome,
never undefined behavior).

### `@todo("msg", window)`
The only legal temporal note. The `window` is mandatory; past it the directive is a **compile
error**. It is recorded in the index ([`29`](29-architecture-governance.md) §2). There are
**four window forms** — one obvious spelling each
([`29`](29-architecture-governance.md) §4):

| Form | Grammar | Example | Expires |
|---|---|---|---|
| relative duration | `<int>` + unit `h`/`d`/`w`/`mo`/`q`/`y` | `30d` | that long after the introducing build |
| absolute date | ISO-8601 `YYYY-MM-DD` | `2026-09-01` | on that date |
| build count | `<int>builds` | `50builds` | after that many builds |
| task ref | `T-<digits>` | `T-0042` | when the task closes — the **recommended default** |

`@todo("rebalance drops", T-0042)`. The build-clock that dates a window is a **recorded input** to
`funpack build` ([`29`](29-architecture-governance.md) §1/§4) — an argument, never ambient — so the
window is evaluated as a pure function of `(source, clock)`; a `T-`ref resolves against the operator's
task tooling, outside the engine. The forms are mutually unambiguous: a date carries two `-`, a task ref leads with `T-`, and
a duration and a build count differ by their trailing unit.

---

## 3. Data-plane indices (the runtime self-index)

### `@index(Thing.field)` / `@spatial(Thing.field)`
Direct the engine to maintain a **deterministic instance-level index** over a thing's field —
`@index` for reverse/key lookup, `@spatial` for built-in radius/nearest queries. An index is a pure
function of state (a cache, rebuilt on load) with a defined, `Id`-tiebroken order. The compiler
**gates** them: a `query` whose access needs an index requires its declaration, and an `@index` no
query uses is flagged dead code ([`08`](08-state.md)). This is the runtime sibling of `@gtag`.

**Placement is query-prefix only.** `@index`/`@spatial` prefix a `query` declaration
([`08`](08-state.md) §3) and **nothing else** — prefixing any other declaration kind is the compile
error `Index_Wrong_Target`. The indexed `FieldPath`'s head **must be a declared `thing` or
`singleton`**; a head that names no declared `thing`/`singleton` is the compile error
`Index_Unknown_Thing`.

| Subject the directive prefixes | Verdict |
|---|---|
| a `query` declaration | accepted — the only legal placement |
| any non-`query` declaration | `Index_Wrong_Target` |
| `FieldPath` head names a declared `thing`/`singleton` | accepted |
| `FieldPath` head names anything else | `Index_Unknown_Thing` |

This is the minimal, recoverable cut: widening placement later (to a `thing`-declaration or
field-position site) is non-breaking; narrowing it is not.

---

## 4. Boundaries & projection

### `@expose`
Publishes a declaration into a generated external-API contract — the **one visibility primitive**,
shared by packages (a package's public API, `<name>.api.gen.fun`) and mods (the game↔mod
`*.modapi.gen.fun` interface). Inert (it publishes an interface, never expands into code) and the
*inverse* of `extern`: `extern` exposes natives downward to funpack code, `@expose` exposes a contract
upward to a consumer — a package importer (a *peer*) or a mod (*confined*) ([`30`](30-packages.md),
[`27`](27-modding.md)).

### `@server` / `@client` (the realm family)
Assign a declaration's network realm, driving the projection that compiles one source into **two
artifacts** (server, client) for a multiplayer build. Realm is **inferred structurally** where the
type decides (render ⇒ `@client`; egress/secret ⇒ `@server`); annotation overrides only where
needed. Server-only code is unnameable in the client by closure — anti-cheat by projection
([`25`](25-netcode.md)).

---

## 5. Debug (dev-only observability)

### `@break(pred)` / `@log(expr)` / `@watch(expr)` / `@trace`
Breakpoints, structured logging, watchpoints, and step-traces placed **in source**, where they are
auditable and self-anchoring across agent runs. Argument shapes ([`28`](28-introspection.md) §4):
`@break(<pred>)` pauses when a funpack **predicate** over `self`/signals/resources holds;
`@log(<expr>)` and `@watch(<expr>)` take a funpack **expression** — the value to emit or watch
(`@watch` may also prefix a `data` field); `@trace` takes **no argument** (it prefixes a behavior or a
pipeline stage). The argument is ordinary funpack, not a debugger DSL. They are **observe-class** — pause, read, or emit,
**never alter logic** — so determinism holds, and they are **release-forbidden and task-registered
like `@stub`**, so debug residue can neither ship nor rot. They are the in-code form of the live
introspection contract ([`28`](28-introspection.md)).

---

## 6. Evolution

### `@migrate`
The dedicated breaking-change channel for save/schema/mod-contract evolution — the two structural
breaks the schema-diff cannot auto-resolve, **rename** and **retype** ([`09`](09-runtime.md) §4,
[`24`](24-persistence.md)). It prefixes the renamed/retyped **field** (or a renamed type
declaration); because `data` is name-keyed, it names the prior key and, when the type changed, a pure
conversion:

| Change | Form | Reads |
|---|---|---|
| rename (same type) | `@migrate(from: "old_name")` | the old key into the new field |
| retype (same name) | `@migrate(with: convert)` | the old value through `convert` |
| rename + retype | `@migrate(from: "old_name", with: convert)` | both |

`from:` is the prior name as a `String`; `with:` is a pure `fn(Old) -> New`. The directive is inert
(it drives the loader, never expanding into code); an unresolved rename/retype without it is a
compile error ([`09`](09-runtime.md) §4).

`with:` admissibility is checkable exactly this far and no further: the conversion is a
**module-declared named `fn`** (an `extern fn` qualifies — asserted purity is the [`26`](26-stdlib.md)
native boundary), of **arity 1**, whose **return type equals the field's declared type**. The
parameter type is **deliberately unchecked** — it is the migration's claim about a prior schema that
no longer exists at compile time. Lambdas and imported conversions are not admitted: a conversion is
auditable migration logic and lives as a named declaration in the module that owns the data.

### Enum-variant evolution

The `@migrate` field/type channel above cannot reach a **variant** rename or removal, so a committed
enum token must be governed by its own two-part rule — a load-time floor, plus an opt-in migration
channel.

**Floor — unknown-variant refusal (mandatory).** On restore/reload ([`24`](24-persistence.md),
[`09`](09-runtime.md) §4), a committed enum token naming **no variant in the new schema** is **refused**
— the load **fails closed**, never carrying the token through. This preserves [`03`](03-data-model.md)
§2 forced-totality: the world never holds a live enum token that no `match` arm can name. The refusal
is unconditional and is not a directive — it is the floor that holds whether or not `@migrate` is
present.

**Channel — `@migrate` on an enum variant (opt-in).** `@migrate` extends to an enum variant for the
two evolutions the schema-diff cannot auto-resolve:

| Change | Form | Reads |
|---|---|---|
| variant rename | `@migrate(from: "Old_Token")` on the new variant | the old committed token as the new variant |
| variant removal with live committed tokens | — (no per-variant migration target) | refuses unless retargeted by a rename on a surviving variant |

`from:` is the prior variant token as a `String`. A variant **removal** is therefore only safe when no
committed token names it, or when its committed tokens are retargeted by a `from:` rename onto a
surviving variant; an unmigrated removal that leaves live committed tokens hits the floor and refuses.
A variant rename is **token-only** — it does not admit a payload `with:` conversion (the field/type
channel above owns payload retype).
