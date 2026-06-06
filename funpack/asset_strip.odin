// The §19 §5 release-mode dead-asset elimination: the P5 dead-code gate applied
// to CONTENT. Release bakes everything, then strips — any asset no handle
// references is removed, "so truncation is never silent" (§19.5). This is the
// last asset seam in the §19 chain and the one downstream of seam emission
// (asset_seam_emit.odin): it walks the EMITTED handle set against the manifest's
// closed registry (asset_manifest.odin) to compute reachability, then drops the
// unreached entries. Dev never strips — it bakes the dirty subgraph on demand and
// hot-reloads (§19.5), so a handle is always a valid reference even mid-edit; the
// release-only gate is what trades that liveness for a minimal shipped set.
//
// THE REFERENCE GRAPH (what reachability is): a referencer is a behavior (or any
// reader) that names an asset through its typed handle — `assets.pickups` in
// draw_coin, `assets.coin_sfx` in on_pickup (examples/assets/src/pickups.fun). The
// graph is referencer → asset-name edges; an Asset_Reference is one such edge. A
// manifest entry is REACHABLE iff at least one edge names it. The example coin
// model is unreachable (the 2D build draws the sprite atlas, not the mesh — refs
// 0), so release strips it; pickups and coin_sfx are reached once each and kept.
//
// PURITY (spec §09, §29): every proc here is a pure function of (manifest,
// references) — the reach is the edge set folded onto the manifest by index, the
// strip is a slice partition in committed order, no map iteration whose order the
// runtime could shuffle. Same manifest + same edges → same reach → same kept/
// stripped partition, on any machine.
package funpack

// Bake_Mode is the closed §19.5 bake-mode set the strip gate keys on. Dev bakes
// the dirty subgraph and NEVER strips (a handle is always a valid reference, even
// mid-edit, so liveness is preserved); Release bakes everything then strips the
// unreached set. A third mode is a deliberate addition here in lockstep with the
// spec, never a silently-tolerated fall-through.
Bake_Mode :: enum {
	Dev,
	Release,
}

// Asset_Reference is one edge of the §19.5 reference graph: a referencer (the
// behavior or reader naming the asset through its typed handle, e.g.
// "pickups.draw_coin") pointing at the registered asset name it reaches (e.g.
// "pickups"). The flat reachability set (which names ARE referenced) is the
// []string the dead-code gate walks; this struct carries the extra referencer
// attribution the §5 report renders on each kept asset's `<- referencer` tail.
Asset_Reference :: struct {
	by:    string, // the referencer — the behavior/reader that names the asset
	asset: string, // the registered asset name it reaches
}

// Asset_Reach is the reference graph folded onto the manifest by index: one
// Asset_Reach_Entry per manifest entry, IN COMMITTED ORDER (the slice is the
// registry, never a map), recording whether each asset is reached, how many
// referencers reach it, and the first referencer that did. It is the input both
// to the strip (an entry with ref_count 0 is dead) and to the report (the
// `refs N <- referencer` columns read straight off it).
Asset_Reach :: struct {
	entries: []Asset_Reach_Entry,
}

// Asset_Reach_Entry is one manifest entry's reachability verdict: its registered
// name (so the strip and report need not re-index the manifest), the count of
// referencers that reach it (refs N in the report; 0 means dead), and the first
// referencer's label (the report's `<- referencer` tail; empty when ref_count is
// 0, since a dead asset has no referencer to name). referenced is the bare
// ref_count > 0 predicate the strip partitions on.
Asset_Reach_Entry :: struct {
	name:       string,
	referenced: bool,
	ref_count:  int,
	referencer: string,
}

// asset_references computes which manifest entries the used handles reach: the P5
// dead-code gate applied to content. handles_used is the flat reachability set —
// the registered asset names some handle references (the proof's
// {pickups, coin_sfx}). It walks the manifest in committed order and, per entry,
// counts how many entries of handles_used name it (ref_count) and marks it
// referenced when that count is non-zero. An asset absent from handles_used gets
// ref_count 0 and referenced=false — the dead asset release strips. The reach
// carries no referencer label from this overload (a bare name set names no
// referencer); attribute_referencers folds the referencer edges in for the report.
asset_references :: proc(handles_used: []string, manifest: Asset_Manifest, allocator := context.allocator) -> Asset_Reach {
	entries := make([]Asset_Reach_Entry, len(manifest.entries), allocator)
	for entry, i in manifest.entries {
		count := 0
		for used in handles_used {
			if used == entry.name {
				count += 1
			}
		}
		entries[i] = Asset_Reach_Entry {
			name       = entry.name,
			referenced = count > 0,
			ref_count  = count,
			referencer = "",
		}
	}
	return Asset_Reach{entries = entries}
}

// attribute_referencers folds the reference-graph edges onto an Asset_Reach: for
// each reach entry, it records the FIRST edge (in references order) whose `asset`
// names it as that entry's referencer label, the `<- referencer` tail the §5
// report renders. The reach's ref_count/referenced (the strip's input) are NOT
// touched here — they were already fixed by asset_references over the flat
// reachability set; this overload adds only the report attribution, so the strip
// gate and the report attribution stay separable. A reach with no matching edge
// keeps its empty referencer (a dead asset has none to name).
attribute_referencers :: proc(reach: Asset_Reach, references: []Asset_Reference) {
	for &entry in reach.entries {
		for ref in references {
			if ref.asset == entry.name {
				entry.referencer = ref.by
				break
			}
		}
	}
}

// strip_unreferenced is the §19.5 release strip: it partitions the manifest into
// the kept assets (some handle reaches them, ref_count > 0) and the stripped
// assets (no handle reaches them, dead content), both in committed order so the
// partition is deterministic. This is the release-mode path — it ALWAYS strips the
// unreached set, since release "bakes everything, then strips"; the dev path
// (strip_for_mode with .Dev) keeps everything. The reach must be the one computed
// for THIS manifest (entries align by index with reach.entries), so the partition
// reads each entry's verdict straight off the aligned reach entry.
strip_unreferenced :: proc(manifest: Asset_Manifest, reach: Asset_Reach, allocator := context.allocator) -> (kept: []Asset_Entry, stripped: []Asset_Entry) {
	kept_dyn := make([dynamic]Asset_Entry, 0, len(manifest.entries), allocator)
	stripped_dyn := make([dynamic]Asset_Entry, 0, 1, allocator)
	for entry, i in manifest.entries {
		if i < len(reach.entries) && reach.entries[i].referenced {
			append(&kept_dyn, entry)
		} else {
			append(&stripped_dyn, entry)
		}
	}
	return kept_dyn[:], stripped_dyn[:]
}

// strip_for_mode is the §19.5 mode gate over the strip: Release bakes everything
// then strips the unreached set (delegating to strip_unreferenced); Dev bakes the
// dirty subgraph and NEVER strips — every entry is kept and nothing is stripped,
// so a handle stays a valid reference even mid-edit and hot-reload works. The dev
// arm is the spec's "dev mode bakes the dirty subgraph and never strips" made
// mechanical: it returns the full manifest as kept and an empty stripped set,
// independent of the reach (a dev bake does not consult reachability to decide
// what ships).
strip_for_mode :: proc(manifest: Asset_Manifest, reach: Asset_Reach, mode: Bake_Mode, allocator := context.allocator) -> (kept: []Asset_Entry, stripped: []Asset_Entry) {
	switch mode {
	case .Release:
		return strip_unreferenced(manifest, reach, allocator)
	case .Dev:
		kept_dyn := make([dynamic]Asset_Entry, 0, len(manifest.entries), allocator)
		for entry in manifest.entries {
			append(&kept_dyn, entry)
		}
		return kept_dyn[:], []Asset_Entry{}
	}
	return manifest.entries, []Asset_Entry{}
}
