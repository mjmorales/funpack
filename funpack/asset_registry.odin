package funpack

Asset_Constructor :: enum {
	Mesh,
	Atlas,
	Sound,
}

Asset_Registry_Error :: enum {
	None,
	Unregistered_Name,
	Wrong_Kind,
}

asset_name_registered :: proc(manifest: Asset_Manifest, name: string) -> bool {
	for entry in manifest.entries {
		if entry.name == name {
			return true
		}
	}
	return false
}

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
