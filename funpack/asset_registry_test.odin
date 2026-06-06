// The §19 §3 / P7 closed asset-name registry gate unit suite: an asset name not
// in the manifest is a COMPILE ERROR through BOTH addressing forms (the typed
// constant `assets.NAME` and the string constructor `kind("NAME")`), a registered
// name resolves, and a string constructor naming an asset of the wrong kind
// (`sound("coin")` where coin is a model) is its own reject. The fixtures are
// hand-built manifests — small closed registries — so the gate is proven on its
// own, independent of the on-disk golden.
package funpack

import "core:testing"

// registry_fixture builds a three-asset closed registry: coin/model, pickups/
// atlas, coin_sfx/audio — one of each closed kind, mirroring the §19 golden so the
// gate is exercised over every constructor-to-kind pairing. Only name and kind
// matter to the registry; the other fields are left zero.
registry_fixture :: proc(allocator := context.allocator) -> Asset_Manifest {
	entries := make([]Asset_Entry, 3, allocator)
	entries[0] = Asset_Entry{name = "coin", kind = .Model}
	entries[1] = Asset_Entry{name = "pickups", kind = .Atlas}
	entries[2] = Asset_Entry{name = "coin_sfx", kind = .Audio}
	return Asset_Manifest{entries = entries}
}

// test_unregistered_asset_name_is_compile_error is the load-bearing P7
// acceptance: a name absent from the manifest fails the registry through BOTH
// forms — asset_name_registered is false (the typed-constant form has no emitted
// handle to resolve) AND the string constructor gate returns Unregistered_Name
// (`mesh("krognid_torso")` against a registry without it). The closed registry
// makes a referenced-but-missing asset a compile error, never a silent nothing.
@(test)
test_unregistered_asset_name_is_compile_error :: proc(t: ^testing.T) {
	manifest := registry_fixture(context.temp_allocator)

	// The typed-constant form: the name is not in the closed registry, so it has
	// no emitted let-binding to resolve — asset_name_registered is the predicate
	// behind that unresolved reference.
	testing.expect(t, !asset_name_registered(manifest, "krognid_torso"))

	// The string-constructor form: the same absent name is Unregistered_Name, the
	// P7 compile error spec'd as `mesh("krognid_torso") cannot resolve to nothing`.
	err := check_asset_reference(manifest, .Mesh, "krognid_torso")
	testing.expect_value(t, err, Asset_Registry_Error.Unregistered_Name)
}

// test_registered_asset_name_resolves is the happy path: a name in the manifest is
// registered (both forms pass), so the typed constant and the matching-kind string
// constructor both resolve — the §19 golden's `assets.coin_sfx == sound("coin_sfx")`
// holds because both forms name the same registered audio asset.
@(test)
test_registered_asset_name_resolves :: proc(t: ^testing.T) {
	manifest := registry_fixture(context.temp_allocator)

	testing.expect(t, asset_name_registered(manifest, "coin_sfx"))
	testing.expect(t, asset_name_registered(manifest, "coin"))
	testing.expect(t, asset_name_registered(manifest, "pickups"))

	// The string constructor with the matching kind resolves clean — sound names
	// the audio asset, mesh names the model, atlas names the atlas.
	testing.expect_value(t, check_asset_reference(manifest, .Sound, "coin_sfx"), Asset_Registry_Error.None)
	testing.expect_value(t, check_asset_reference(manifest, .Mesh, "coin"), Asset_Registry_Error.None)
	testing.expect_value(t, check_asset_reference(manifest, .Atlas, "pickups"), Asset_Registry_Error.None)
}

// test_string_constructor_wrong_kind_is_rejected pins the kind half of the string
// form: a constructor naming a REGISTERED asset of the wrong kind — `sound("coin")`
// where coin is a model — is Wrong_Kind, not a silent coercion. The asset exists,
// but the constructor's kind disagrees with the registered kind, so the reference
// cannot stand (the same build-error class as an unresolved name).
@(test)
test_string_constructor_wrong_kind_is_rejected :: proc(t: ^testing.T) {
	manifest := registry_fixture(context.temp_allocator)

	// coin is a model; sound("coin") names it with the audio constructor.
	testing.expect_value(t, check_asset_reference(manifest, .Sound, "coin"), Asset_Registry_Error.Wrong_Kind)
	// coin_sfx is audio; mesh("coin_sfx") names it with the model constructor.
	testing.expect_value(t, check_asset_reference(manifest, .Mesh, "coin_sfx"), Asset_Registry_Error.Wrong_Kind)
}

// test_empty_registry_rejects_every_name keeps the closed-registry floor honest at
// the boundary: an empty manifest registers nothing, so every name fails both
// forms. A bake with no assets cannot resolve any asset reference.
@(test)
test_empty_registry_rejects_every_name :: proc(t: ^testing.T) {
	empty := Asset_Manifest{}

	testing.expect(t, !asset_name_registered(empty, "coin"))
	testing.expect_value(t, check_asset_reference(empty, .Mesh, "coin"), Asset_Registry_Error.Unregistered_Name)
}
