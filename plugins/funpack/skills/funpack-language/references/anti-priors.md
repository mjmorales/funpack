# funpack anti-priors — what you may recall vs. what is current

A capable model has very likely **seen funpack in its training data** — and it also knows Lua,
GDScript, Python, Rust, and JS cold. Both push you toward a form that is either a *deprecated*
funpack shape or a *foreign-language* import funpack rejects. When you reach for a left-column form,
write the funpack form instead.

**Origin** decodes the bad prior so you can recalibrate:

- **funpack — …** : an earlier funpack used this; your prior is stale (the version anchors are
  intentional provenance, not stale temporal prose).
- **foreign prior — …** : funpack *never* accepted this — you imported it from another language.

funpack-internal deprecations are listed first, then the foreign-language imports.

| You may write…                                      | funpack form                                                                 | Origin |
|-----------------------------------------------------|------------------------------------------------------------------------------|--------|
| `Spawn{ Ball{…} }`                                  | `Spawn( Ball{…} )` — command-wrap is **call** syntax; `Despawn()`            | funpack — early 0.x used braces, unified to parens; a bare `UPPER{…}` is now *always* a record literal |
| `thing X {…}` + `Spawn( X{} )` in `setup` for a one-of | `singleton X {…}` — engine spawns it before tick 0, accessed by type      | funpack — older examples spawned a `thing`; `singleton` is canonical |
| a lambda body with multiple statements              | one statement only — an expr, an `if`-expr, or a `return`; push logic into a named `fn` | funpack — lambda body was widened to exactly this; also a foreign block-lambda prior |
| `match draw(rng) { (v, next) => … }` per draw, or a `data` carrier to dodge nesting | `let (v, next) = draw(rng)` — destructure a return-position tuple directly; thread `next` into the next `let` | funpack — `let` destructure was once rejected (the only destructure was a `match` arm, so sequential `Rng` threading nested past the depth gate); it is now the threaded-`Rng` consume idiom |
| `xs.map(x => x + 1)`                                | `map(xs, fn(x){ return x + 1 })` — `=>` is the **match-arm** separator only | foreign prior — JS/C#/Rust arrow |
| `a && b`, `a \|\| b`, `!a`                          | `a and b`, `a or b`, `not a` (the words)                                     | foreign prior — C/JS/Rust |
| `null` / `nil` / `undefined`                        | `Option[T]` with `Some`/`None`; absence is a value, matched exhaustively     | foreign prior — most languages |
| `x?` / `try x` to propagate an error                | exhaustive `match`, or `or_else(opt, default)`                               | foreign prior — Rust `?` |
| `for …`, `while …`                                  | `map` / `filter` / `find`; `fold(xs, init, fn(acc, x){…})` is the deterministic loop | foreign prior — imperative langs |
| `var x`, `x = y` (reassign), `let mut`              | `let x = …` (immutable) + `self with { x: … }`                              | foreign prior — Rust/JS/Swift |
| `"score: " + n`                                     | interpolation — `"score: {n}"`                                               | foreign prior — JS/Python/Java string `+` |
| `#[derive(Eq, Hash)]` / `derives`                   | nothing — `Eq`/`Ord`/`Hash`/serialization are synthesized **unconditionally** | foreign prior — Rust derive |
| `// comment`, `/* … */`, `# …`                      | `@doc("…")` (timeless), `@todo("…", window)`, `@gtag(…)`, `@stub(T)`         | foreign prior — universal; funpack has none |
| implicit last-expression return                     | explicit `return` always — no value leaves a `fn` without it                 | foreign prior — Rust/Ruby tail expression |
| `42.5f` in sim, `8 * 0.5f`                           | `Fixed` literals (`8.0`, `0.5`); the `f`-suffix is `Float`, render/audio only | foreign prior — float is the universal default; funpack's determinism rule bans it in sim |
| `someInt + aFixed`                                  | lift first — `to_fixed(someInt) + aFixed`; there is **no** implicit `Int → Fixed` | foreign prior — implicit numeric promotion |
| `fn box[T](…)`, `data Box[T]`                       | no user type parameters — generics (`Option`, `[T]`, `Map`, `View`, `Ref`) are **engine-only** | foreign prior — Rust/TS/Go generics |
| `module foo`, `import ../x`, `self::`, `super::`    | no `module` keyword (the file **path** is the name); imports are absolute and rooted | foreign prior — Rust/TS module decls |
| `pub` / `export`                                    | `@expose`, and only across a **package** edge; within a project everything imports | foreign prior — Rust/TS visibility |
| writing another entity — `other.hp -= 1`            | a behavior writes **only `self`**; to affect another thing, **emit a `signal`** it folds | foreign prior — OOP/ECS mutable references |

For the paradigm-level mapping (ECS/OOP/imperative → the funpack model), see the
**translate-from-known-language** section of the `funpack-author` agent and the `funpack-game-model`
skill; this table is the form-by-form surface correction.
