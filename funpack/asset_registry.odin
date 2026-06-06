// The §19 §3 / P7 closed asset-name registry check: the compile-time gate that
// makes the manifest the single source of every asset name, so a name not in it
// resolves to nothing and is a COMPILE ERROR — `mesh("krognid_torso")` cannot
// silently resolve to a missing asset. The manifest (asset_manifest.odin) is the
// closed registry; this file is the lookup and the gate over it.
//
// BOTH ADDRESSING FORMS are covered, because the typed constant and the string
// constructor name the same asset (the §19 golden pins `assets.coin_sfx ==
// sound("coin_sfx")`):
//   - the typed constant `assets.NAME` — the emitted handle let-binding; an
//     unregistered NAME has no emitted constant, so the reference is unresolved.
//   - the manifest-checked string constructor `kind("NAME")` — mesh/atlas/sound;
//     the gate checks NAME against the registry AND that the constructor's kind
//     matches the registered asset's kind, so even the string form is typo-proof
//     and wrong-kind-proof at build (`sound("coin")` where coin is a model fails).
//
// PURITY (spec §09, §29): both procs are pure functions of the manifest and the
// queried name. The registry is the manifest's entries walked by index — no map
// iteration whose order the runtime could shuffle, matching the reader's
// determinism tripwire — so the same manifest and name always yield the same
// verdict.
package funpack

// Asset_Constructor is the closed set of §19 string-constructor forms that name an
// asset by string: `mesh("…")`, `atlas("…")`, `sound("…")`. Each maps 1:1 to the
// Asset_Kind it resolves: a constructor naming an asset of a different kind is a
// wrong-kind reject, not a silent coercion. (engine.assets also exposes texture,
// but the §19 closed asset kinds the manifest registers are model/atlas/audio, so
// the manifest-backed constructors are mesh/atlas/sound.)
Asset_Constructor :: enum {
	Mesh,
	Atlas,
	Sound,
}

// Asset_Registry_Error is closed with one arm per way an asset reference fails the
// P7 registry gate; None is the only passing arm (the name is registered and, for
// a string constructor, its kind matches). A new reject is a deliberate addition
// here, mirroring the gates.odin / fpm_gates.odin closed-error discipline.
Asset_Registry_Error :: enum {
	None,
	// Unregistered_Name: the name is absent from the manifest — the closed
	// registry has no asset by that name, so neither the typed constant nor the
	// string constructor can resolve. The P7 compile error: a referenced asset
	// that does not exist (`mesh("krognid_torso")` against an empty registry).
	Unregistered_Name,
	// Wrong_Kind: the name IS registered, but a string constructor named it with
	// the wrong kind — `sound("coin")` where coin is a model. The asset exists; the
	// constructor's kind disagrees with the registered kind, which is the same
	// class of build error as an unresolved name (the reference cannot stand).
	Wrong_Kind,
}

// asset_name_registered reports whether `name` is in the manifest's closed
// registry — the bare membership test both addressing forms gate on. It walks the
// entries by index (the registry is the slice, never a map), so the verdict is a
// deterministic function of the committed manifest. This is the P7 predicate: a
// false here is the reason a reference is a compile error.
asset_name_registered :: proc(manifest: Asset_Manifest, name: string) -> bool {
	for entry in manifest.entries {
		if entry.name == name {
			return true
		}
	}
	return false
}

// check_asset_reference is the P7 gate over a string-constructor reference
// `ctor("name")` (mesh/atlas/sound): it turns an unregistered name into
// Unregistered_Name and a kind mismatch into Wrong_Kind, and returns None only
// when the name is registered AND the constructor's kind matches the registered
// asset's kind. The typed-constant form (`assets.NAME`) needs no kind argument —
// it is gated by emission alone (an unregistered NAME has no emitted let-binding),
// so its registry check is asset_name_registered; this proc is the stricter
// string-form gate that also pins the kind.
check_asset_reference :: proc(manifest: Asset_Manifest, ctor: Asset_Constructor, name: string) -> Asset_Registry_Error {
	for entry in manifest.entries {
		if entry.name != name {
			continue
		}
		if entry.kind != constructor_kind(ctor) {
			return .Wrong_Kind
		}
		return .None
	}
	return .Unregistered_Name
}

// constructor_kind maps a string constructor onto the Asset_Kind it must resolve:
// mesh → Model, atlas → Atlas, sound → Audio. The mapping is total over the closed
// constructor set, so the wrong-kind check is exhaustive — every constructor has
// exactly one legal registered kind.
constructor_kind :: proc(ctor: Asset_Constructor) -> Asset_Kind {
	switch ctor {
	case .Mesh:
		return .Model
	case .Atlas:
		return .Atlas
	case .Sound:
		return .Audio
	}
	return .Model
}
