# 02 — Language core

Lexis, literals, operators, names, expressions, and statements of the `.fun` language. Declaration
*semantics* live in [`03`](03-data-model.md)–[`08`](08-state.md); this file fixes their grammar and
everything below the declaration line.

The statement layer is strictly **LL(1)** — every declaration and statement opens with a unique
keyword, so one token of lookahead selects the production. Expressions use a Pratt
(precedence-climbing) parser. A canonical formatter ships in `funpack`, is mandatory and idempotent;
the AST is the source of truth and text is its projection.

---

## 1. Lexis

- **No comments.** The `.fun` lexer has no comment production (P6). Documentation is `@doc`; temporal
  intent is `@todo`/`@stub`. (`//` is permitted only in the imperative `.fpm` bake DSL — [`16`](16-modeling.md).)
- **Statement terminator is the newline.** Blocks are brace-delimited. The formatter re-indents, so
  whitespace is never counted.
- **Separators** between fields, variants, and list elements are **newline or `,`** — both legal; a
  trailing `,` is allowed in multi-line forms. The formatter normalizes.
- **Identifiers & casing** (formatter-enforced; a wrong case is a compile error, not a silent rename):
  - `UpperCamel` — type names (`data`/`enum`/`thing`/`singleton`/`signal`/`pipeline`) and enum
    variants.
  - `snake_case` — values, functions, behaviors, fields, parameters, modules.
  - `UPPER_SNAKE` — module-level `let` constants (`GRID`, `ACCEL`, `SIGHT`). Stdlib well-known
    mathematical constants (`pi`, `tau`) are the one sanctioned lowercase exception.

---

## 2. Literals

| Form | Type | Notes |
|---|---|---|
| `42` | `Int` | the one integer type — 64-bit signed, saturating ([`10`](10-numerics.md)) |
| `42.5`, `0.0`, `8.0` | `Fixed` | the sim-default; **no** implicit Int→Fixed promotion — lift with `to_fixed(n)` |
| `42.5f` | `Float` | **render/visual-only**; a float-suffixed literal in sim/pure code is a compile error |
| `"…"` | `String` | interpolation `"{expr}"`; `\{` escapes a brace; **never** built with `+` |
| `true` / `false` | `Bool` | logic via the words `and`/`or`/`not` |
| `60hz`, `8hz` | tick rate | a fixed simulation rate; legal in an entrypoint's wiring (see [`07`](07-pipelines.md), [`14`](14-project-config.md)) |
| `[a, b]` / `[]` | list | elements newline- or comma-separated |
| `Name{f: v, …}` | record | a `data`/`thing`/`signal`/`enum`-struct value; defaulted fields may be omitted (`Snake{}`) |
| `Spawn(<thing-literal>)` | command | the command wraps a thing literal **as a call argument** (no field name); the engine assigns the `Id` ([`08`](08-state.md)) |

---

## 3. Operators & one-concept-per-glyph

Each glyph carries exactly one semantic concept (P2); none needs more than one token of lookahead to
resolve its role.

| Glyph | Sole meaning |
|---|---|
| `=` | binding — after `let`, as a declared field default, or as a `.fcfg` config assignment. **Never** equality. |
| `:` | type ascription — annotates a value (`field: T`, `let x: T`) and ascribes a kind to a type declaration (`Name: Kind`, §7); field separator in a record literal / declaration |
| `::` | **enum-variant selector, only** (`Dir::Up`, `Option::Some`, `Color::White`) |
| `.` | member access — record field, UFCS method, or a type's associated function/constant (§4) |
| `->` | function return type |
| `=>` | match arm |
| `[ ]` | list literal / list type / index / generic application (`Option[T]`, `View[T]`) — all "sequence or type-application by position" |
| `{ }` | block; record literal; type/`pipeline` body |
| `( )` | grouping; call arguments; return-position tuple (§8) |
| `@` | directive prefix ([`05`](05-directives.md)) |
| `with` | record-update expression (§5) |

`Int` is the **one** integer type — 64-bit signed, with saturating arithmetic, mirroring the
one-`Fixed`-format, total-saturating numeric doctrine ([`10`](10-numerics.md)). There are no other
integer widths and no unsigned integer types.

Arithmetic `+ - * / %`; comparison `== != < <= > >=`; logic `and or not`. Arithmetic and comparison
are defined on the numeric and `Num`-kinded engine types (`Fixed`, `Int`, `Vec2`, `Vec3`); there is
**no** operator overloading elsewhere, no `&&`/`||`/`!`, no `<>` generics, no pointer/deref sigils.
`..` (range) is **not** part of the `.fun` expression grammar — it appears only in the level DSL
([`17`](17-levels.md)), consistent with §6's no-loop rule.

**Pratt precedence**, low → high:
`or` → `and` → `== !=` → `< <= > >=` → `+ -` → `* / %` → unary (`not`, `-`) → `with` →
call/index/member → atom.

---

## 4. Names & the calling convention

A **method call and a free-function call are the same function**; `.` is the universal call/access
operator and `::` is reserved for enum variants.

- `recv.f(args)` resolves `.f` in order: (1) a **field** of `recv`; (2) **UFCS** — a function whose
  first parameter (`self`) has `recv`'s type, with `recv` passed as that argument (`prepend(self,
  item)` is called `xs.prepend(item)`; `apply_impulse(self, v)` is `body.apply_impulse(v)`); (3) an
  associated function in the receiver type's module.
- `Type.f(args)` / `Type.CONST` names an **associated** function or constant in that type's module:
  constructors and statics (`View.of([…])`, `Bindings.empty()`, `Time.at(dt)`, `String.join(parts,
  sep)`, `Pose.empty()`) and associated constants (`Fixed.MAX`, `Fixed.MIN`, `Quat.identity`).
- Chaining is left-to-right method application: `Bindings.empty().axis(…).button(…)`.

**Imports** name what a module brings into scope:

```
import engine.math.{Vec2, abs, clamp}     // selected members
import engine.grid.grid_cells             // a single member
import assets                             // the whole module (members accessed as assets.coin_sfx)
```

---

## 5. Expressions

Expression-oriented: `if` and `match` **yield values**. A function nonetheless produces its value
**only** through an explicit `return` (§6) — there is no implicit last-expression return.

- **`if`** — `if cond { … } else { … }`, usable as a statement or an expression (incl. inside a match
  arm or a lambda body).
- **`match`** — `match e { pattern => expr-or-block … }`, arms newline-separated, **exhaustive**
  (a non-total match is a compile error). Patterns:
  - variant with binders — `Option::Some(v)`, `Dir::Up`
  - struct-field pun — `Shape2::Box{size} => size`
  - tuple — `(Option::Some(wp), rest) => …` (destructures a return-position tuple, §8)
  - wildcard — `_`
- **`with`** — `value with { field: v, … }`: a new value with fields replaced (COW). Nests
  (`self.settings with { access: a }`) and applies to a fresh literal (`Menu{} with { dirty: true }`).
- **Lambda** — `fn(params) { … return … }`. Parameter and result types are inferred in combinator
  position; nesting is allowed. Used with `map`/`filter`/`fold`/`find`. A lambda body is a **single
  statement** — one expression, an if-expression, or a `return` — never a multi-statement block;
  complex logic belongs in a named `fn`.
- **Call / index / member** — `f(a, b)`, `xs[i]` (where defined; list access is normally the total
  `xs.get(i) -> Option`), `a.b`.
- **Interpolation** — `"score {m.score} of {m.total}"`.

---

## 6. Statements

- **`let`** — `let name: Type = expr` (the type annotation is optional where inferable). The only
  binding form; there is no `var`/`set`. All locals are immutable; state evolves by `with` and by
  returning new values. The sole sanctioned mutation is `mut data` ([`03`](03-data-model.md)).
  - **Tuple destructure** — `let (a, b, …) = expr` binds each name to its position in a
    return-position tuple (§5, §8): the threaded-`Rng` consume site `let (value, next) = draw(rng)`,
    where each `engine.rand` draw returns `(value, nextRng)`. The binder count must equal the tuple
    arity (a mismatch, or a non-tuple right-hand side, is a compile error). The binder list is a flat
    sequence of plain names — for anything richer than a return-tuple consume, use `match`. A `(`
    immediately after `let` selects this form.
- **`return`** — `return expr`. Mandatory to produce a function's value.
- **No `for` / `while`.** The functional core has no imperative loops. Iteration is the list
  combinators (`map`, `filter`, `fold`, `find`); `fold` is the deterministic loop primitive, folding
  strictly left-to-right ([`10`](10-numerics.md)). This removes mutable loop state and fixes a
  defined iteration order (P1/P2).
- **No `?` operator.** Optional/result propagation is explicit — `match` or `or_else`.
- **Expression statement** — a bare call whose result is unused (rare; most calls feed a `let` or a
  `return`).

---

## 7. Declaration inventory (grammar only)

Every declaration opens with one keyword. Semantics are specified in the linked component.

There is **no `module` keyword** — a module's name is its file path under the source root, and a
file-leading `@doc` documents it ([`15`](15-modules.md)).

| Keyword | Form | Component |
|---|---|---|
| `import` | see §4 | [`15`](15-modules.md) |
| `let` | `let NAME: T = expr` (module-level constant) | here / [`03`](03-data-model.md) |
| `data` | `data Name { field: T = default … }`; optional kind `data Name: Num { … }` (engine-only) | [`03`](03-data-model.md) |
| `enum` | `enum Name { Variant, Variant(T), Variant{f: T} }`; optional kind `enum Name: Kind { … }`; generic `enum Option[T] { … }` | [`03`](03-data-model.md) |
| `thing` | `thing Name { field: T = default … }` | [`06`](06-things-behaviors.md) |
| `singleton` | `singleton Name { … }` (exactly one, engine-managed) | [`06`](06-things-behaviors.md) |
| `signal` | `signal Name { field: T }` (the canonical inter-behavior message) | [`03`](03-data-model.md) / [`06`](06-things-behaviors.md) |
| `behavior` | `behavior name on Thing { fn step(self, …) -> … { … } }` | [`06`](06-things-behaviors.md) |
| `fn` | `fn name(p: T, …) -> R { … }`; stub body `@stub(R)` | here / [`04`](04-effects.md) |
| `pipeline` | `pipeline Name { stage: [behaviors] … }` (ordered stages only) | [`07`](07-pipelines.md) |
| `query` | `query name(p: T) -> [T] { … }` (read-only, memoized world read) | [`08`](08-state.md) |
| `test` | `test "name" { assert expr … }` | [`04`](04-effects.md) |
| `extern fn` / `extern type` | native boundary; stdlib/privileged only | [`26`](26-stdlib.md) |

---

## 8. Canonical forms

- `match` arms are `=>`.
- No `var`/`set`/mutation keywords, no `!{…}` effect rows, no `comp`/`sys`/`struct`.
- `::` is variant-only; the type-path use of `::` is folded into `.`.
- **Tuples exist only as the return-position multi-value form** — a behavior's `-> (self,
  [Signal])`, a multi-return `fn -> ([A], [B])`, and the `let`/`match` that destructures such a
  return. A tuple is **not** a general first-class type: there are **no** tuple-typed `data` fields
  and **no** tuple variables threaded through code. For any stored or named aggregate, `data` —
  named, map-backed ([`03`](03-data-model.md)) — is the one obvious way (P1).
