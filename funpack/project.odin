// Project-tree reader for the §14-enforced layout: funpack errors on a
// malformed tree as it errors on a malformed function — there is no
// alternative arrangement and no override flag. The .fcfg parse here is
// identity-only by design (name + version); the full config grammar is a
// separate seam.
package funpack

import "core:os"
import "core:path/filepath"
import "core:strings"

Project :: struct {
	name:    string,
	version: string,
	sources: []string,
}

Project_Error :: enum {
	None,
	Missing_Configs_Dir,
	Missing_Project_Fcfg,
	Malformed_Project_Fcfg,
	Missing_Src_Dir,
	No_Sources,
}

read_project :: proc(root: string) -> (project: Project, err: Project_Error) {
	configs_dir, _ := filepath.join({root, "funpack_configs"}, context.temp_allocator)
	if !os.is_dir(configs_dir) {
		return Project{}, .Missing_Configs_Dir
	}
	fcfg_path, _ := filepath.join({configs_dir, "project.fcfg"}, context.temp_allocator)
	fcfg_bytes, read_err := os.read_entire_file_from_path(fcfg_path, context.allocator)
	if read_err != nil {
		return Project{}, .Missing_Project_Fcfg
	}
	name, version, parse_ok := parse_project_identity(string(fcfg_bytes))
	if !parse_ok {
		return Project{}, .Malformed_Project_Fcfg
	}
	sources, src_err := collect_sources(root)
	if src_err != .None {
		return Project{}, src_err
	}
	return Project{name = name, version = version, sources = sources}, .None
}

// Identity-only scan of project.fcfg: `project <name> {` plus
// `version = "<v>"`. Anything beyond those two facts is ignored rather
// than rejected, so the stub stays forward-compatible with the full
// config grammar.
parse_project_identity :: proc(content: string) -> (name: string, version: string, ok: bool) {
	it := content
	for raw_line in strings.split_lines_iterator(&it) {
		line := strings.trim_space(raw_line)
		if strings.has_prefix(line, "project ") && strings.has_suffix(line, "{") {
			name = strings.trim_space(strings.trim_suffix(line[len("project "):], "{"))
		}
		if strings.has_prefix(line, "version") {
			_, _, value := strings.partition(line, "=")
			version = strings.trim(strings.trim_space(value), "\"")
		}
	}
	ok = name != "" && version != ""
	return
}

collect_sources :: proc(root: string) -> ([]string, Project_Error) {
	src_dir, _ := filepath.join({root, "src"}, context.temp_allocator)
	if !os.is_dir(src_dir) {
		return nil, .Missing_Src_Dir
	}
	pattern, _ := filepath.join({src_dir, "*.fun"}, context.temp_allocator)
	sources, glob_err := filepath.glob(pattern)
	if glob_err != nil || len(sources) == 0 {
		return nil, .No_Sources
	}
	return sources, .None
}
