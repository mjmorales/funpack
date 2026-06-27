package funpack

import "core:testing"

registry_fixture :: proc(allocator := context.allocator) -> Asset_Manifest {
	entries := make([]Asset_Entry, 3, allocator)
	entries[0] = Asset_Entry{name = "coin", kind = .Model}
	entries[1] = Asset_Entry{name = "pickups", kind = .Atlas}
	entries[2] = Asset_Entry{name = "coin_sfx", kind = .Audio}
	return Asset_Manifest{entries = entries}
}

@(test)
test_unregistered_asset_name_is_compile_error :: proc(t: ^testing.T) {
	manifest := registry_fixture(context.temp_allocator)

	testing.expect(t, !asset_name_registered(manifest, "krognid_torso"))

	err := check_asset_reference(manifest, .Mesh, "krognid_torso")
	testing.expect_value(t, err, Asset_Registry_Error.Unregistered_Name)
}

@(test)
test_registered_asset_name_resolves :: proc(t: ^testing.T) {
	manifest := registry_fixture(context.temp_allocator)

	testing.expect(t, asset_name_registered(manifest, "coin_sfx"))
	testing.expect(t, asset_name_registered(manifest, "coin"))
	testing.expect(t, asset_name_registered(manifest, "pickups"))

	testing.expect_value(t, check_asset_reference(manifest, .Sound, "coin_sfx"), Asset_Registry_Error.None)
	testing.expect_value(t, check_asset_reference(manifest, .Mesh, "coin"), Asset_Registry_Error.None)
	testing.expect_value(t, check_asset_reference(manifest, .Atlas, "pickups"), Asset_Registry_Error.None)
}

@(test)
test_string_constructor_wrong_kind_is_rejected :: proc(t: ^testing.T) {
	manifest := registry_fixture(context.temp_allocator)

	testing.expect_value(t, check_asset_reference(manifest, .Sound, "coin"), Asset_Registry_Error.Wrong_Kind)
	testing.expect_value(t, check_asset_reference(manifest, .Mesh, "coin_sfx"), Asset_Registry_Error.Wrong_Kind)
}

@(test)
test_empty_registry_rejects_every_name :: proc(t: ^testing.T) {
	empty := Asset_Manifest{}

	testing.expect(t, !asset_name_registered(empty, "coin"))
	testing.expect_value(t, check_asset_reference(empty, .Mesh, "coin"), Asset_Registry_Error.Unregistered_Name)
}
