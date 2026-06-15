# 19 — The asset pipeline

Every content system — models ([`16`](16-modeling.md)), UI ([`21`](21-ui.md)), levels
([`17`](17-levels.md)), tilesets and atlases ([`18`](18-tilemaps.md)), audio ([`22`](22-audio.md)),
fonts — shares one shape, specified once here:

> **`source → importer → (content-hashed asset + generated `.gen.fun` seam)`.** The importer is a
> deterministic pure function; the content hash is the asset's identity, cache key, and what makes
> builds incremental; the seam is the typed contract, committed and diffable.

The bake is part of the **`funpack`** binary (pure `source → artifact`,
[`29`](29-architecture-governance.md)), so it is build-deterministic by construction — no wall clock,
no network, no machine paths leak into an artifact.

## 1. One shape for every asset

| Source | Authored as | Importer produces | Seam |
|---|---|---|---|
| `.fpm` model | DSL | mesh + collider, hashed | params `data`, anchors, `MeshHandle` |
| `.fui` screen | DSL | view program | view-model `data`, `Msg` enum, view fn |
| `.flvl` level | DSL | spawn data + tile layers | `Ref` table, `*_spawns`, `TilemapHandle` |
| `.tiles` tileset | DSL | tile defs (cell + collision) | `TilesetHandle` |
| `.atlas` sprite sheet | image + slice spec | atlas (regions + clips) | `AtlasHandle` (+ named cells/clips) |
| audio (WAV/OGG) | raw | decoded buffer | `SoundHandle` |
| font (TTF) | raw | glyph atlas | `Font` |

Two source flavors, one pipeline: **authored DSLs** bake through their importer and emit a seam; **raw
external files** are content-hashed directly through a binary importer. Both end as a content-hashed
asset.

## 2. Content hash = identity = cache key

```
hash(asset) = H( source bytes ⊕ importer version ⊕ hashes of its dependencies )
```

This one rule buys: **build determinism** (same inputs ⇒ same hash ⇒ byte-identical artifact
anywhere); **free caching** (the hash is the cache key — a bake whose hash is already in the
content-addressed store is skipped, so every build after the first is incremental); and **correct
invalidation** (bumping an importer's version changes the hash of everything it produced — a kernel
fix rebuilds exactly its outputs and their dependents, never more). Determinism comes from *caching
the result*, not re-deriving it at runtime.

## 3. The manifest & the name registry

The bake emits a **manifest** — a committed, diffable index mapping each stable asset **name** →
content hash → output location + metadata (the example `assets.manifest`: `[coin] kind=model source=…
importer="model@3" deps=[] hash="sha256:…" out=".cache/…"`). It is the source of truth for resolving
a handle, and its diff is a review surface.

**Asset names are a closed registry, checked at compile time** (the `@gtag`-for-assets, P7): a name
not in the manifest is a **compile error**, so `mesh("krognid_torso")` cannot resolve to nothing at
runtime. The bake also generates a typed **`Assets` seam** of handle constants — one per registered
asset, lowercase, namespaced by folder:

```funpack
let coin:     MeshHandle  = MeshHandle{name: "coin"}
let coin_sfx: SoundHandle = SoundHandle{name: "coin_sfx"}
```

The **default, safest** addressing is the typed constant (`assets.coin_sfx`) — no string, no possible
typo, propagation holds (rename the source ⇒ the constant disappears ⇒ readers stop compiling). The
string constructors (`mesh("…")`, `atlas("…")`, `sound("…")`) remain for **dynamic, data-driven**
lookups and are **checked against the manifest**, so even the string form is typo-proof at build
(`assets.coin_sfx == sound("coin_sfx")`).

## 4. The dependency DAG & importers

Assets form a graph (an atlas depends on its image; a tileset on an atlas; a level on tilesets,
models, and the placed things' schemas). Each output records its input hashes, so a source edit
invalidates only the **dirty subgraph**, the bake is an order-independent, parallelizable walk over a
DAG of pure functions, and a cycle is a build error.

There is **one importer per source kind**, an **engine-closed** battery (not user-authored), each a
deterministic pure function; binary importers (PNG/WAV/TTF/glTF) are Tier-1 native but contracted
deterministic. A genuinely new importer is the **escape hatch** — an `extern` importer in
custom-runtime mode — never needed on the common path.

**Per-platform texture-compression format is an importer/implementation detail with no authoring
surface** — choosing BCn/ASTC/ETC per target is the texture importer's concern, folded into the
content hash via its importer version (§2), and never specified in funpack or named by a handle. A
texture is authored and referenced by name; its on-disk encoding is invisible to game code.

## 5. The generated seam & where it runs

Every importer yielding funpack-visible types emits a **committed, formatter-canonical,
regenerated-on-bake** `.gen.fun`: it lets the strict world typecheck **before any bake has run**, its
diff is the **review record** for a content change, and a stale committed seam is a build error.

- **`funpack` owns the bake** (pure); the cache is content-addressed and local by default; a
  shared/remote cache is a build-infrastructure concern outside the pure bake.
- **Dev** bakes the dirty subgraph on demand and **hot-reloads** — handles resolve through the
  manifest, so swapping an artifact under a stable name updates the running game live; a *type*
  change in a regenerated seam is a recompile, not a hot-swap.
- **Release** bakes everything, then **strips**: **dead-asset elimination** removes any asset no
  handle references (the P5 dead-code gate applied to content). The bake emits an **asset report**
  (counts, sizes, the reference graph, what was stripped — the example `assets.report.txt`: "baked 3,
  stripped 1 (unreferenced) … shipped 9 KB across 2 assets"), so truncation is never silent.

**Asset residency is a transparent engine concern behind typed handles.** Streaming and lazy loading —
when an artifact is paged into memory and when it is evicted — are engine-side scheduling against the
content-addressed store; authoring references a typed handle (`assets.coin`, §3) and is **unaffected by
residency**. There is no load/unload authoring surface for asset memory, no "is-loaded" query in sim
code: a handle is always a valid reference, and resolving it is the engine's job. (Level *chunk*
streaming — `Load`/`Unload` over a `LevelHandle`, [`17`](17-levels.md)#4 — is a separate, explicit
gameplay-spawn concern, not asset residency.)

Asset names are namespaced by folder; the manifest records each asset's importer version, and a
release pins those versions.
