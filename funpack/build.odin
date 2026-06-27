package funpack

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

FUNPACK_BUILD_DIR :: ".funpack"

ARTIFACT_PRODUCT_NAME :: "artifact"

INDEX_PRODUCT_NAME :: "index.ndjson"

Build_Product :: struct {
	artifact:      string,
	index:         string,
	artifact_path: string,
	index_path:    string,
}

Build_Mode :: enum {
	Dev,
	Release,
}

Build_Error :: enum {
	None,
	Malformed_Tree,
	Compile_Failed,
	Index_Failed,
	Holed_Declaration,
	Debug_Directive,
	Asset_Bake_Failed,
}

Build_Verdict :: struct {
	err:        Build_Error,
	offender:   string,
	diagnostic: Diagnostic,
}

build_refusal_message :: proc(verdict: Build_Verdict, allocator := context.allocator) -> string {
	if verdict.offender == "" {
		return fmt.aprintf("%v", verdict.err, allocator = allocator)
	}
	return fmt.aprintf("%v: %s", verdict.err, verdict.offender, allocator = allocator)
}

stage_asset_bake :: proc(root: string, allocator := context.allocator) -> Build_Verdict {
	baked, bake_err, bake_detail := bake_asset_manifest(root, context.temp_allocator)
	if bake_err != .None {
		return Build_Verdict{err = .Asset_Bake_Failed, offender = asset_bake_refusal_message(bake_err, bake_detail, allocator)}
	}
	emitted := emit_asset_manifest(baked, context.temp_allocator)
	if stale_err, stale_detail := bake_manifest_staleness(root, emitted); stale_err != .None {
		return Build_Verdict{err = .Asset_Bake_Failed, offender = asset_bake_refusal_message(stale_err, stale_detail, allocator)}
	}
	return Build_Verdict{}
}

asset_bake_refusal_message :: proc(err: Asset_Bake_Error, detail: string, allocator := context.allocator) -> string {
	switch err {
	case .None:
		return ""
	case .Stale_Manifest:
		return fmt.aprintf("Stale_Manifest: %s does not match the freshly-baked manifest — regenerate it (FUNPACK_REGEN_GOLDEN=1 funpack build) and commit the diff", detail, allocator = allocator)
	case .Missing_Manifest:
		return fmt.aprintf("Missing_Manifest: %s — a tree that bakes assets must carry the generated manifest", detail, allocator = allocator)
	case .Malformed_Manifest:
		return fmt.aprintf("Malformed_Manifest: %s — the committed manifest does not parse", detail, allocator = allocator)
	case .Missing_Source:
		return fmt.aprintf("Missing_Source: %s — a registered asset source is not on disk", detail, allocator = allocator)
	case .Malformed_Source:
		return fmt.aprintf("Malformed_Source: %s — an asset source rejected its importer", detail, allocator = allocator)
	case .Missing_Image:
		return fmt.aprintf("Missing_Image: %s — an atlas names an image file that is not on disk", detail, allocator = allocator)
	case .Malformed_Image:
		return fmt.aprintf("Malformed_Image: %s — an image file could not be decoded", detail, allocator = allocator)
	}
	return fmt.aprintf("%v: %s", err, detail, allocator = allocator)
}

regen_asset_manifest :: proc(root: string) -> (err: Asset_Bake_Error, detail: string) {
	if !asset_tree_has_manifest(root) {
		return .None, ""
	}
	baked, bake_err, bake_detail := bake_asset_manifest(root, context.temp_allocator)
	if bake_err != .None {
		return bake_err, bake_detail
	}
	emitted := emit_asset_manifest(baked, context.temp_allocator)
	if !write_asset_manifest(root, emitted) {
		return .Missing_Manifest, asset_manifest_path(root, context.temp_allocator)
	}
	return .None, ""
}

stage_build :: proc(root: string, mode: Build_Mode, allocator := context.allocator) -> (product: Build_Product, verdict: Build_Verdict) {
	project, project_err, project_detail := read_project(root)
	if project_err != .None {
		return Build_Product{}, Build_Verdict{err = .Malformed_Tree, offender = project_refusal_message(project_err, project_detail, allocator)}
	}
	if len(project.sources) == 0 {
		return Build_Product{}, Build_Verdict{err = .Malformed_Tree}
	}
	if asset_tree_has_manifest(root) {
		if bake_verdict := stage_asset_bake(root, allocator); bake_verdict.err != .None {
			return Build_Product{}, bake_verdict
		}
	}
	sources := project_pipeline_sources(project)
	if mode == .Release {
		scan_sources := order_release_sources(root, sources)
		if name, holed := project_holed_decl(scan_sources); holed {
			return Build_Product{}, Build_Verdict{err = .Holed_Declaration, offender = name}
		}
		if name, probed := project_debug_decl(scan_sources); probed {
			return Build_Product{}, Build_Verdict{err = .Debug_Directive, offender = name}
		}
	}
	if gate := project_gate_verdict(sources); gate.err != .None {
		return Build_Product{}, gate
	}
	is_game := has_entrypoints_fcfg(root)
	artifact := ""
	artifact_path := ""
	if is_game {
		emit_err: Emit_Error
		artifact, emit_err = emit_tree_artifact(root, project, sources, allocator)
		if emit_err != .None {
			return Build_Product{}, compile_failed_verdict(sources)
		}
		artifact_path = build_product_path(root, ARTIFACT_PRODUCT_NAME, allocator)
	}
	index, index_err, _, compiled := read_index_project(root, allocator)
	if index_err != .None {
		return Build_Product{}, Build_Verdict{err = .Index_Failed}
	}
	if !compiled {
		return Build_Product{}, compile_failed_verdict(sources)
	}
	return Build_Product {
			artifact      = artifact,
			index         = index,
			artifact_path = artifact_path,
			index_path    = build_product_path(root, INDEX_PRODUCT_NAME, allocator),
		},
		Build_Verdict{}
}

compile_failed_verdict :: proc(sources: []Source) -> Build_Verdict {
	report := run_project_pipeline(sources)
	return Build_Verdict{err = .Compile_Failed, diagnostic = report.diagnostic}
}

project_gate_verdict :: proc(sources: []Source) -> Build_Verdict {
	for source in sources {
		ast, ok := parse_source(source.path)
		if !ok {
			continue
		}
		if verdict := gate_verdict(ast); verdict.err != .None {
			diag := gate_diagnostic(verdict.err, verdict.line, verdict.declaration, verdict.nesting_cause)
			diag.path = source.path
			return Build_Verdict{err = .Compile_Failed, diagnostic = diag}
		}
	}
	return Build_Verdict{}
}

project_first_decl :: proc(sources: []Source, predicate: proc(ast: Ast) -> (string, bool)) -> (declaration: string, found: bool) {
	for source in sources {
		ast, ok := parse_source(source.path)
		if !ok {
			continue
		}
		if name, hit := predicate(ast); hit {
			return qualify_offender(sources, source, name), true
		}
	}
	return "", false
}

project_holed_decl :: proc(sources: []Source) -> (declaration: string, holed: bool) {
	return project_first_decl(sources, release_holed_decl)
}

project_debug_decl :: proc(sources: []Source) -> (declaration: string, probed: bool) {
	return project_first_decl(sources, release_debug_decl)
}

qualify_offender :: proc(sources: []Source, source: Source, name: string) -> string {
	module := source.module
	if len(sources) == 1 {
		module = ""
	}
	return qualify_decl(module, name)
}

order_release_sources :: proc(root: string, sources: []Source) -> []Source {
	names := make([]string, len(sources), context.temp_allocator)
	for source, i in sources {
		names[i] = source.module
	}
	ordered := make([]Source, len(sources), context.temp_allocator)
	for src, dst in entrypoint_first_order(names, entrypoint_module_name(root)) {
		ordered[dst] = sources[src]
	}
	return ordered
}

has_entrypoints_fcfg :: proc(root: string) -> bool {
	path, _ := filepath.join({root, "funpack_configs", "entrypoints.fcfg"}, context.temp_allocator)
	return os.exists(path)
}

emit_tree_artifact :: proc(root: string, project: Project, sources: []Source, allocator := context.allocator) -> (artifact: string, err: Emit_Error) {
	entrypoint_path, _ := filepath.join({root, "funpack_configs", "entrypoints.fcfg"}, context.temp_allocator)
	entrypoint_bytes, ep_err := os.read_entire_file_from_path(entrypoint_path, context.temp_allocator)
	if ep_err != nil {
		return "", .Entrypoint_Failed
	}
	entry_module := entrypoint_module_name(root)
	source, found := select_entrypoint_source(sources, entry_module)
	if !found {
		return "", .Entrypoint_Failed
	}
	source_bytes, read_err := os.read_entire_file_from_path(source.path, context.temp_allocator)
	if read_err != nil {
		return "", .Parse_Failed
	}
	index := build_project_module_index(sources)
	tilemaps, level_spawns, baked_ok := bake_tree_levels(root, sources, index, allocator)
	if !baked_ok {
		return "", .Gate_Failed
	}
	nav_graphs := bake_tree_nav_graphs(tilemaps, allocator)
	assets := Baked_Assets{}
	if asset_tree_has_manifest(root) {
		baked_assets, assets_err, _ := bake_tree_assets(root, allocator)
		if assets_err != .None {
			return "", .Gate_Failed
		}
		assets = baked_assets
	}
	sibling_asts := build_sibling_module_asts(sources, source.module)
	identity := Project_Identity{name = project.name, version = project.version}
	return stage_emit_indexed(string(source_bytes), source.module, identity, string(entrypoint_bytes), index, sibling_asts, tilemaps, nav_graphs, level_spawns, assets, allocator)
}

bake_tree_levels :: proc(root: string, sources: []Source, index: Module_Index, allocator := context.allocator) -> (layers: []Baked_Tile_Layer, level_spawns: []Level_Spawn_Batch, ok: bool) {
	level_paths := collect_level_paths(root)
	if len(level_paths) == 0 {
		return nil, nil, true
	}
	tilesets, tilesets_ok := read_tree_tilesets(root)
	if !tilesets_ok {
		return nil, nil, false
	}
	table, table_err := flvl_project_tile_table(tilesets, context.temp_allocator)
	if table_err != .None {
		return nil, nil, false
	}
	out := make([dynamic]Baked_Tile_Layer, 0, 2, allocator)
	batches := make([dynamic]Level_Spawn_Batch, 0, 2, allocator)
	for path in level_paths {
		level_bytes, read_err := os.read_entire_file_from_path(path, context.temp_allocator)
		if read_err != nil {
			return nil, nil, false
		}
		level, parse_err := parse_flvl(string(level_bytes))
		if parse_err != .None {
			return nil, nil, false
		}
		schema_source, has_schema := select_entrypoint_source(sources, level.things_module)
		if !has_schema {
			return nil, nil, false
		}
		schema_bytes, schema_read := os.read_entire_file_from_path(schema_source.path, context.temp_allocator)
		if schema_read != nil {
			return nil, nil, false
		}
		schema_ast, schema_parse := stage_parse(stage_lex(string(schema_bytes)))
		if schema_parse != .None {
			return nil, nil, false
		}
		baked, bake_err := bake_flvl(level, schema_ast, level.things_module, index, table)
		if bake_err != .None {
			return nil, nil, false
		}
		for layer in baked.tile_layers {
			append(&out, clone_tile_layer(layer, allocator))
		}
		append(&batches, Level_Spawn_Batch {
			fn_name = level_spawns_fn_name(baked, allocator),
			spawns  = clone_spawns(baked.spawns, allocator),
		})
	}
	return out[:], batches[:], true
}

clone_spawns :: proc(spawns: []Baked_Spawn, allocator := context.allocator) -> []Baked_Spawn {
	out := make([]Baked_Spawn, len(spawns), allocator)
	for spawn, i in spawns {
		cloned := spawn
		cloned.thing_type = strings.clone(spawn.thing_type, allocator)
		params := make([]Baked_Param, len(spawn.params), allocator)
		for param, j in spawn.params {
			params[j] = param
			params[j].field = strings.clone(param.field, allocator)
		}
		cloned.params = params
		out[i] = cloned
	}
	return out
}

Baked_Nav_Graph :: struct {
	name:  string,
	nodes: []Nav_Node,
	edges: []Nav_Edge,
}

Nav_Node :: struct {
	x: Fixed,
	y: Fixed,
}

Nav_Edge :: struct {
	a: int,
	b: int,
}

bake_tree_nav_graphs :: proc(layers: []Baked_Tile_Layer, allocator := context.allocator) -> []Baked_Nav_Graph {
	graphs := make([]Baked_Nav_Graph, len(layers), allocator)
	for layer, i in layers {
		graphs[i] = bake_layer_nav_graph(layer, allocator)
	}
	return graphs
}

bake_layer_nav_graph :: proc(layer: Baked_Tile_Layer, allocator := context.allocator) -> Baked_Nav_Graph {
	cell_to_node := make([]int, len(layer.cells), context.temp_allocator)
	node_count := 0
	for r in 0 ..< layer.rows {
		for c in 0 ..< layer.cols {
			cell := r * layer.cols + c
			if nav_cell_walkable(layer, layer.cells[cell]) {
				cell_to_node[cell] = node_count
				node_count += 1
			} else {
				cell_to_node[cell] = -1
			}
		}
	}
	nodes := make([]Nav_Node, node_count, allocator)
	edges := make([dynamic]Nav_Edge, 0, node_count * 2, allocator)
	half := fixed_div(to_fixed(layer.cell_size), to_fixed(2))
	for r in 0 ..< layer.rows {
		for c in 0 ..< layer.cols {
			cell := r * layer.cols + c
			node := cell_to_node[cell]
			if node < 0 {
				continue
			}
			off := fixed_add(to_fixed(int_mul(i64(c), layer.cell_size)), half)
			nodes[node].x = fixed_add(layer.anchor_x, off)
			nodes[node].y = fixed_sub(layer.anchor_y, fixed_add(to_fixed(int_mul(i64(r), layer.cell_size)), half))
			if c + 1 < layer.cols {
				if right := cell_to_node[cell + 1]; right >= 0 {
					append(&edges, Nav_Edge{a = node, b = right})
				}
			}
			if r + 1 < layer.rows {
				if down := cell_to_node[cell + layer.cols]; down >= 0 {
					append(&edges, Nav_Edge{a = node, b = down})
				}
			}
		}
	}
	return Baked_Nav_Graph{name = strings.clone(layer.name, allocator), nodes = nodes, edges = edges[:]}
}

nav_cell_walkable :: proc(layer: Baked_Tile_Layer, cell: int) -> bool {
	if cell == TILE_LAYER_EMPTY_CELL {
		return true
	}
	return !layer.palette[cell].solid
}

clone_tile_layer :: proc(layer: Baked_Tile_Layer, allocator := context.allocator) -> Baked_Tile_Layer {
	cloned := layer
	cloned.name = strings.clone(layer.name, allocator)
	cloned.atlas = strings.clone(layer.atlas, allocator)
	palette := make([]Baked_Tile, len(layer.palette), allocator)
	for tile, i in layer.palette {
		palette[i] = Baked_Tile{name = strings.clone(tile.name, allocator), solid = tile.solid, cell_x = tile.cell_x, cell_y = tile.cell_y}
	}
	cells := make([]int, len(layer.cells), allocator)
	copy(cells, layer.cells)
	cloned.palette = palette
	cloned.cells = cells
	return cloned
}

collect_level_paths :: proc(root: string) -> []string {
	dir, _ := filepath.join({root, "levels"}, context.temp_allocator)
	if !os.is_dir(dir) {
		return nil
	}
	paths := make([dynamic]string, 0, 4, context.temp_allocator)
	walker := os.walker_create(dir)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if info.type != .Regular || !strings.has_suffix(info.name, ".flvl") {
			continue
		}
		append(&paths, strings.clone(info.fullpath, context.temp_allocator))
	}
	slice.sort(paths[:])
	return paths[:]
}

read_tree_tilesets :: proc(root: string) -> (tilesets: []Tileset_Asset, ok: bool) {
	manifest_path, _ := filepath.join({root, "assets", "assets.manifest"}, context.temp_allocator)
	manifest_bytes, read_err := os.read_entire_file_from_path(manifest_path, context.temp_allocator)
	if read_err != nil {
		return nil, true
	}
	manifest, manifest_err := read_asset_manifest(string(manifest_bytes))
	if manifest_err != .None {
		return nil, false
	}
	out := make([dynamic]Tileset_Asset, 0, 2, context.temp_allocator)
	for entry in manifest.entries {
		if entry.kind != .Tileset {
			continue
		}
		source_path, _ := filepath.join({root, "assets", entry.source}, context.temp_allocator)
		source_bytes, source_err := os.read_entire_file_from_path(source_path, context.temp_allocator)
		if source_err != nil {
			return nil, false
		}
		tileset, import_err := import_tileset(string(source_bytes), entry.deps, context.temp_allocator)
		if import_err != .None {
			return nil, false
		}
		append(&out, tileset)
	}
	return out[:], true
}

build_sibling_module_asts :: proc(sources: []Source, entry_module: string) -> map[string]Ast {
	asts := make(map[string]Ast, len(sources), context.temp_allocator)
	for s in sources {
		if s.module == entry_module {
			continue
		}
		ast, ok := parse_source(s.path)
		if !ok {
			continue
		}
		asts[s.module] = ast
	}
	return asts
}

select_entrypoint_source :: proc(sources: []Source, module: string) -> (source: Source, found: bool) {
	if module == "" {
		return Source{}, false
	}
	for s in sources {
		if s.module == module {
			return s, true
		}
	}
	return Source{}, false
}

build_project_module_index :: proc(sources: []Source) -> Module_Index {
	modules := make([]string, len(sources), context.temp_allocator)
	asts := make([]Ast, len(sources), context.temp_allocator)
	package_roots := make([]string, len(sources), context.temp_allocator)
	for source, i in sources {
		modules[i] = source.module
		package_roots[i] = source.package_root
		ast, ok := parse_source(source.path)
		if !ok {
			continue
		}
		asts[i] = ast
	}
	return build_module_index_typed(modules, asts, package_roots)
}

build_product_path :: proc(root: string, leaf: string, allocator := context.allocator) -> string {
	path, _ := filepath.join({root, FUNPACK_BUILD_DIR, leaf}, allocator)
	return path
}

Build_Write_Error :: enum {
	None,
	Mkdir_Failed,
	Write_Artifact_Failed,
	Write_Index_Failed,
}

write_build_products :: proc(product: Build_Product, root: string) -> Build_Write_Error {
	build_dir, _ := filepath.join({root, FUNPACK_BUILD_DIR}, context.temp_allocator)
	if mk_err := os.make_directory(build_dir); mk_err != nil && mk_err != os.General_Error.Exist {
		return .Mkdir_Failed
	}
	wrote_artifact := false
	if product.artifact_path != "" {
		if write_err := os.write_entire_file(product.artifact_path, transmute([]u8)product.artifact); write_err != nil {
			return .Write_Artifact_Failed
		}
		wrote_artifact = true
	}
	if write_err := os.write_entire_file(product.index_path, transmute([]u8)product.index); write_err != nil {
		if wrote_artifact {
			os.remove(product.artifact_path)
		}
		return .Write_Index_Failed
	}
	return .None
}
