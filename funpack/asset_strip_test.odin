// The §19 §5 release dead-asset-elimination unit fixtures: the reference-graph
// walk (asset_references) and the strip partition (strip_unreferenced /
// strip_for_mode) over the committed examples/assets reference set. The proof the
// task pins: given handles {pickups, coin_sfx} used, the release strip drops the
// coin model (refs 0 — the 2D build draws the sprite atlas, not the mesh) and
// keeps the other two; and dev mode strips nothing. The reference set is built BY
// HAND here over the example manifest, so the test pins the gate's logic, not a
// round-trip through the bake.
package funpack

import "core:testing"

// strip_example_manifest is the three-entry committed example manifest the strip
// walks — coin/model, pickups/atlas, coin_sfx/audio in committed order. Only the
// fields the reach/strip read (name, kind) carry their golden values; the rest are
// placeholder, so the fixture pins the strip's input shape, not the manifest reader.
strip_example_manifest :: proc(allocator := context.allocator) -> Asset_Manifest {
	entries := make([]Asset_Entry, 3, allocator)
	entries[0] = Asset_Entry{name = "coin", kind = .Model}
	entries[1] = Asset_Entry{name = "pickups", kind = .Atlas}
	entries[2] = Asset_Entry{name = "coin_sfx", kind = .Audio}
	return Asset_Manifest{entries = entries}
}

// test_strip_drops_unreferenced_coin_keeps_two is the load-bearing acceptance: with
// the used-handle set {pickups, coin_sfx}, the release strip keeps pickups and
// coin_sfx (each reached once) and strips the coin model (reached zero times — no
// handle reaches it). It pins the partition members, their committed order, and
// that the dropped one is exactly the model coin.
@(test)
test_strip_drops_unreferenced_coin_keeps_two :: proc(t: ^testing.T) {
	manifest := strip_example_manifest(context.temp_allocator)
	handles_used := []string{"pickups", "coin_sfx"}
	reach := asset_references(handles_used, manifest, context.temp_allocator)

	kept, stripped := strip_unreferenced(manifest, reach, context.temp_allocator)

	testing.expect_value(t, len(kept), 2)
	testing.expect_value(t, len(stripped), 1)
	// Kept holds pickups and coin_sfx in committed order; the model coin is gone.
	testing.expect_value(t, kept[0].name, "pickups")
	testing.expect_value(t, kept[1].name, "coin_sfx")
	// The single stripped asset is the unreferenced model coin.
	testing.expect_value(t, stripped[0].name, "coin")
	testing.expect_value(t, stripped[0].kind, Asset_Kind.Model)
}

// test_dev_mode_never_strips pins the §19.5 dev arm: dev bakes the dirty subgraph
// and strips NOTHING, so even with the coin unreferenced (the same {pickups,
// coin_sfx} set that strips it in release) dev keeps all three and strips none — a
// handle stays a valid reference mid-edit. The reach is identical; only the mode
// differs, so the test isolates the mode gate, not the reachability walk.
@(test)
test_dev_mode_never_strips :: proc(t: ^testing.T) {
	manifest := strip_example_manifest(context.temp_allocator)
	handles_used := []string{"pickups", "coin_sfx"}
	reach := asset_references(handles_used, manifest, context.temp_allocator)

	kept, stripped := strip_for_mode(manifest, reach, .Dev, context.temp_allocator)

	// Dev keeps every baked asset and strips nothing, regardless of reachability.
	testing.expect_value(t, len(kept), 3)
	testing.expect_value(t, len(stripped), 0)
	testing.expect_value(t, kept[0].name, "coin")
	testing.expect_value(t, kept[1].name, "pickups")
	testing.expect_value(t, kept[2].name, "coin_sfx")
}

// test_strip_for_mode_release_matches_strip_unreferenced pins that the .Release arm
// of the mode gate is the bare strip: it must produce the identical partition
// strip_unreferenced does, so the mode gate adds only the dev short-circuit and
// never alters the release strip's verdict.
@(test)
test_strip_for_mode_release_matches_strip_unreferenced :: proc(t: ^testing.T) {
	manifest := strip_example_manifest(context.temp_allocator)
	handles_used := []string{"pickups", "coin_sfx"}
	reach := asset_references(handles_used, manifest, context.temp_allocator)

	direct_kept, direct_stripped := strip_unreferenced(manifest, reach, context.temp_allocator)
	mode_kept, mode_stripped := strip_for_mode(manifest, reach, .Release, context.temp_allocator)

	testing.expect_value(t, len(mode_kept), len(direct_kept))
	testing.expect_value(t, len(mode_stripped), len(direct_stripped))
	testing.expect_value(t, mode_kept[0].name, direct_kept[0].name)
	testing.expect_value(t, mode_kept[1].name, direct_kept[1].name)
	testing.expect_value(t, mode_stripped[0].name, direct_stripped[0].name)
}

// test_asset_references_counts_per_entry pins the reachability walk's per-entry
// verdict in isolation: each manifest entry's ref_count is the number of times its
// name appears in handles_used, and referenced is that count > 0. The coin (absent
// from the set) is the dead entry (ref_count 0, referenced false); pickups and
// coin_sfx are reached once each.
@(test)
test_asset_references_counts_per_entry :: proc(t: ^testing.T) {
	manifest := strip_example_manifest(context.temp_allocator)
	handles_used := []string{"pickups", "coin_sfx"}
	reach := asset_references(handles_used, manifest, context.temp_allocator)

	testing.expect_value(t, len(reach.entries), 3)
	// coin (index 0) is unreferenced — the dead asset.
	testing.expect_value(t, reach.entries[0].name, "coin")
	testing.expect_value(t, reach.entries[0].ref_count, 0)
	testing.expect(t, !reach.entries[0].referenced)
	// pickups and coin_sfx are each reached once.
	testing.expect_value(t, reach.entries[1].ref_count, 1)
	testing.expect(t, reach.entries[1].referenced)
	testing.expect_value(t, reach.entries[2].ref_count, 1)
	testing.expect(t, reach.entries[2].referenced)
}

// test_attribute_referencers_folds_first_edge pins that attribute_referencers
// records the FIRST reference-graph edge naming each asset as its referencer label,
// without touching the ref_count the reachability walk already fixed — the report's
// "<- referencer" tail comes from here, the "refs N" from asset_references.
@(test)
test_attribute_referencers_folds_first_edge :: proc(t: ^testing.T) {
	manifest := strip_example_manifest(context.temp_allocator)
	handles_used := []string{"pickups", "coin_sfx"}
	reach := asset_references(handles_used, manifest, context.temp_allocator)

	references := []Asset_Reference {
		{by = "pickups.draw_coin", asset = "pickups"},
		{by = "pickups.on_pickup", asset = "coin_sfx"},
	}
	attribute_referencers(reach, references)

	// The coin has no edge — its referencer stays empty.
	testing.expect_value(t, reach.entries[0].referencer, "")
	// pickups and coin_sfx get their first (only) referencer.
	testing.expect_value(t, reach.entries[1].referencer, "pickups.draw_coin")
	testing.expect_value(t, reach.entries[2].referencer, "pickups.on_pickup")
	// ref_count is untouched by attribution.
	testing.expect_value(t, reach.entries[1].ref_count, 1)
}
