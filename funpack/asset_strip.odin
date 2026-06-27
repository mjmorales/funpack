package funpack

Bake_Mode :: enum {
	Dev,
	Release,
}

Asset_Reference :: struct {
	by:    string,
	asset: string,
}

Asset_Reach :: struct {
	entries: []Asset_Reach_Entry,
}

Asset_Reach_Entry :: struct {
	name:       string,
	referenced: bool,
	ref_count:  int,
	referencer: string,
}

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
