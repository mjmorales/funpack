package funpack

import "core:testing"

strip_example_manifest :: proc(allocator := context.allocator) -> Asset_Manifest {
	entries := make([]Asset_Entry, 3, allocator)
	entries[0] = Asset_Entry{name = "coin", kind = .Model}
	entries[1] = Asset_Entry{name = "pickups", kind = .Atlas}
	entries[2] = Asset_Entry{name = "coin_sfx", kind = .Audio}
	return Asset_Manifest{entries = entries}
}

@(test)
test_strip_drops_unreferenced_coin_keeps_two :: proc(t: ^testing.T) {
	manifest := strip_example_manifest(context.temp_allocator)
	handles_used := []string{"pickups", "coin_sfx"}
	reach := asset_references(handles_used, manifest, context.temp_allocator)

	kept, stripped := strip_unreferenced(manifest, reach, context.temp_allocator)

	testing.expect_value(t, len(kept), 2)
	testing.expect_value(t, len(stripped), 1)
	testing.expect_value(t, kept[0].name, "pickups")
	testing.expect_value(t, kept[1].name, "coin_sfx")
	testing.expect_value(t, stripped[0].name, "coin")
	testing.expect_value(t, stripped[0].kind, Asset_Kind.Model)
}

@(test)
test_dev_mode_never_strips :: proc(t: ^testing.T) {
	manifest := strip_example_manifest(context.temp_allocator)
	handles_used := []string{"pickups", "coin_sfx"}
	reach := asset_references(handles_used, manifest, context.temp_allocator)

	kept, stripped := strip_for_mode(manifest, reach, .Dev, context.temp_allocator)

	testing.expect_value(t, len(kept), 3)
	testing.expect_value(t, len(stripped), 0)
	testing.expect_value(t, kept[0].name, "coin")
	testing.expect_value(t, kept[1].name, "pickups")
	testing.expect_value(t, kept[2].name, "coin_sfx")
}

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

@(test)
test_asset_references_counts_per_entry :: proc(t: ^testing.T) {
	manifest := strip_example_manifest(context.temp_allocator)
	handles_used := []string{"pickups", "coin_sfx"}
	reach := asset_references(handles_used, manifest, context.temp_allocator)

	testing.expect_value(t, len(reach.entries), 3)
	testing.expect_value(t, reach.entries[0].name, "coin")
	testing.expect_value(t, reach.entries[0].ref_count, 0)
	testing.expect(t, !reach.entries[0].referenced)
	testing.expect_value(t, reach.entries[1].ref_count, 1)
	testing.expect(t, reach.entries[1].referenced)
	testing.expect_value(t, reach.entries[2].ref_count, 1)
	testing.expect(t, reach.entries[2].referenced)
}

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

	testing.expect_value(t, reach.entries[0].referencer, "")
	testing.expect_value(t, reach.entries[1].referencer, "pickups.draw_coin")
	testing.expect_value(t, reach.entries[2].referencer, "pickups.on_pickup")
	testing.expect_value(t, reach.entries[1].ref_count, 1)
}
