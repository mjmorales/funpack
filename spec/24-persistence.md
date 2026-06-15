# 24 — Persistence: saves & settings

Two kinds of disk data, kept rigorously apart because they sit on opposite sides of the determinism
boundary:

- **A save is a serialized sim snapshot** — the world and its progress. It *is* sim state, so it
  rides the [`08`](08-state.md) serialization machinery; this component adds the player-facing layer
  (slots, the command surface, migration).
- **Settings are per-machine player preferences** — volume, keybinds, graphics, accessibility. They
  are **not sim state**, are **never read by a behavior**, and never cross the wire; they feed the
  *impure* runtime consumers (the mixer, the binding resolver, the renderer).

Both reach disk the one way funpack does IO: **a command out, a `Result` signal back**
([`04`](04-effects.md)). User code performs no file IO and observes no clock. The decisive line is
"who reads it": if sim code could read a setting, a replay would diverge between two players with
different config — so settings are structurally kept out of the sim.

## 1. Saves — a snapshot, command-driven

`engine.save` surface:

| Command | Outcome signal | Effect |
|---|---|---|
| `Save{slot}` | `Saved{slot, result: Result[SaveInfo, IoError]}` | serialize the committed version → write |
| `Restore{slot}` | `Restored{slot, result: Result[Unit, LoadError]}` | read + migrate + **swap the world at the next tick boundary** |
| `DeleteSave{slot}` | `Deleted{slot, result: Result[Unit, IoError]}` | remove a slot |

```funpack
behavior on_persist_result on Menu {
  fn step(self: Menu, saved: [Saved]) -> Menu {
    return fold(saved, self, fn(m, r) {
      return match r.result {                  // Result[…, IoError] — both arms forced
        Result::Ok(_)  => m with { status: Option::Some("saved") }
        Result::Err(_) => m with { status: Option::Some("save failed") }
      }
    })
  }
}
```

- **`Restore`, not `Load`** — `Load`/`Unload` are level streaming ([`17`](17-levels.md)); restoring
  replaces the *world*, applied at a **tick boundary** (the hot-reload swap seam, [`09`](09-runtime.md)).
- **A hot-reload landing in the persist-deferral window delivers the pending outcome unchanged.**
  A persist command's outcome signal (`Saved`/`Restored`/`SettingsApplied`) is delivered **one tick
  after** the effect commits; a hot-reload that lands in that one-tick deferral window — between the
  committed effect and its owed delivery — **delivers the pending outcome under the new artifact,
  unchanged**. The outcome is a **committed fact** (the save/restore/apply already happened), so it
  is not in-flight gameplay state for the tick boundary to be clean of ([`09`](09-runtime.md) §3) —
  it is owed **exactly-once** delivery, and engine-signal shapes are **schema-stable across reload**
  (an engine signal's shape is fixed by the engine, not migrated like a `data` schema), so the new
  artifact receives the same value the old one would have. Dropping it would lose a fact game logic
  awaits; refusing the reload would be over-restrictive. The reload neither re-issues the effect nor
  re-derives the outcome — it forwards the already-committed result.
- **The snapshot is the whole committed version** — including dynamic tile state
  ([`18`](18-tilemaps.md) §4): a save serializes the live tile layers' delta from the bake, and a
  restore re-applies it, so a dug passage survives save/restore exactly as it survives a reload
  ([`09`](09-runtime.md) §4). Restore inheriting pre-restore terrain is a defect, not a semantics.
- **Slots are dynamic `String` keys** — unlike asset names (a closed compile-time registry), saves are
  created at runtime by the player, so the slot is an honest `String`. The one place a string key is
  correct rather than a smell.
- **Enumeration is a read-only `Saves` resource** (`[SaveInfo]` — slot, label, timestamp, schema
  version, thumbnail); listing the directory is engine IO surfaced as a resource, never user file IO.
- **Migration is not new** — a save carries an **exact-match schema/contract version stamp**, and
  restoring under a changed schema is the **same operation** as hot-reload state migration
  ([`09`](09-runtime.md)): load applies **name-keyed automatic migration** (an additive field defaults,
  a removed field drops, a reorder is a non-event) and **`@migrate` for rename/retype**, else it
  **refuses with a diagnostic**. A `@migrate(from:)` naming a key **absent from the old schema refuses
  outright** — it never falls through to the additive default, because a dangling `from:` means the
  author's model of the prior schema is wrong, and defaulting would load plausible-but-wrong state;
  the refusal is a `Result` value (the world stays untouched, a reload keeps the old artifact running); a removed mod yields *load-with-discard* ([`27`](27-modding.md)).
  `LoadError` enumerates the session-header mismatch cases (`SchemaBreaking`, `ModMissing`,
  `RuntimeMismatch`, `Corrupt`, `NotFound`), each forced into the `match`.
- **Determinism** — the save root is a runtime deploy param, never baked into the artifact. A `Save`
  is an output effect (not re-issued on replay); a `Restore` brings external bytes in, so the restored
  snapshot is content-hash-pinned in the session header, and a recording that includes a mid-session
  restore replays bit-identically.
- **Cloud sync is operator/platform infrastructure** — the engine produces a **serializable versioned
  snapshot** (the save with its schema/contract version stamp) and consumes one back; **conflict
  resolution between two cloud copies is outside engine doctrine** (the operator/platform owns the
  sync policy), the engine's obligation ending at emitting and accepting a versioned snapshot.

## 2. Settings — per-machine, never sim state

```funpack
data Settings { volume: BusGains, binds: Bindings, graphics: GraphicsOpts, access: AccessOpts }
```

Loaded at startup by the runtime from the one per-machine preferences file (separate from saves) and
applied to its three consumers; **no behavior ever reads a setting**:

- **Volume → the engine mixer.** The persisted per-bus master gain is a mixer setting; an in-session
  slider preview may still fold into the projection, but the durable value is engine config.
- **Keybinds → the binding resolver.** The factory `bindings()` ([`23`](23-input.md)) is the default;
  persisted `binds` override it, applied where bindings live — outside the sim, which still sees only
  resolved device-agnostic actions.
- **Graphics/accessibility → the renderer**, visual-only. A reduce-motion option suppressing
  screen-shake is applied **engine-side to the view**; the gameplay shake state is unchanged and
  deterministic.

A settings screen edits an in-session `Settings` value (UI form state in a blackboard); **applying**
emits `ApplySettings{settings}` → `SettingsApplied{result: Result[Unit, IoError]}` (persist to the
prefs file **and** push to the three consumers). The **rebind capture** ("press a key to bind") is
the single place raw device input is read ([`23`](23-input.md)) — an engine/config-layer affordance.
