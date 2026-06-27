package eir

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

ODIN_EXT :: ".odin"
ODIN_TEST_SUFFIX :: "_test.odin"

Discovered :: struct {
	path:    string,
	is_test: bool,
}

discover_odin_sources :: proc(
	root: string,
	excludes: []string,
	allocator := context.allocator,
) -> (
	sources: []Discovered,
	ok: bool,
) {
	abs_root, abs_err := filepath.abs(root, allocator)
	if abs_err != nil {
		return nil, false
	}
	defer delete(abs_root, allocator)

	found := make([dynamic]Discovered, 0, 64, allocator)

	w := os.walker_create(abs_root)
	defer os.walker_destroy(&w)

	for info in os.walker_walk(&w) {
		if _, werr := os.walker_error(&w); werr != nil {
			continue
		}

		rel := path_relative_to(abs_root, info.fullpath)
		if glob_excludes(excludes, rel, info.name) {
			if info.type == .Directory {
				os.walker_skip_dir(&w)
			}
			continue
		}

		if info.type == .Directory {
			continue
		}
		if !strings.has_suffix(info.name, ODIN_EXT) {
			continue
		}

		append(
			&found,
			Discovered {
				path = strings.clone(info.fullpath, allocator),
				is_test = strings.has_suffix(info.name, ODIN_TEST_SUFFIX),
			},
		)
	}

	slice.sort_by(found[:], proc(a, b: Discovered) -> bool {
		return a.path < b.path
	})

	return found[:], true
}

path_relative_to :: proc(root, full: string) -> string {
	if !strings.has_prefix(full, root) {
		return full
	}
	return strings.trim_prefix(full[len(root):], os.Path_Separator_String)
}

glob_excludes :: proc(patterns: []string, rel, name: string) -> bool {
	for pattern in patterns {
		pat := strings.trim_suffix(pattern, "/")
		if matched, err := filepath.match(pat, rel); err == nil && matched {
			return true
		}
		if matched, err := filepath.match(pat, name); err == nil && matched {
			return true
		}
	}
	return false
}
