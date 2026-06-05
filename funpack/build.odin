// The `build` verb's emission seam: the integration point that wires both of
// funpack's emission surfaces — the runtime binary artifact (emit.odin) and the
// Index Contract `project` record NDJSON (index_contract.odin) — onto one §14
// project tree. It reads the tree at the working directory (read_project,
// project.odin), runs the source through the full checked pipeline (parse →
// gates → resolve → typecheck → contracts → flatten/closure) once per emission
// surface, and on success writes BOTH products under the derived, gitignored
// `.funpack/` directory (§14 §1).
//
// EXIT CONTRACT (spec §29 §3; the same contract the test verb honors): a
// malformed §14 tree or ANY compile/gate failure is exit 2 and writes NEITHER
// product — the build either emits both products or none, never a partial tree.
// A compile/gate error is never a counted failure; the build verb has no
// assertion-failure tier (that is the test verb's), so its only outcomes are
// success (0, both products written) and compile/gate/tree error (2, no
// product).
//
// PURITY (spec §09, §29 §1): the products are a pure function of source and the
// authored config. The output paths are derived from the project root per §14
// (`.funpack/` under the root, fixed leaf names), so no absolute machine path is
// baked into either product's bytes — the artifact carries only the §15
// path-derived module name in its spans, and the NDJSON carries no path at all.
// Two builds of the same tree therefore write byte-identical artifact AND
// byte-identical NDJSON.
//
// BOUNDARY: this wires emission into the CLI. It does NOT execute the artifact
// (the runtime owns execution) and does NOT add a new pipeline stage — it
// composes the existing stage_emit and read_index_project seams.
package funpack

import "core:os"
import "core:path/filepath"

// FUNPACK_BUILD_DIR is the §14 derived-products directory (`.funpack/`): the
// gitignored sibling of `funpack_configs/` and `src/` where a build writes its
// products. It is rebuilt on demand and never committed (§14 §1), so the build
// verb creates it if absent and overwrites its contents on every build.
FUNPACK_BUILD_DIR :: ".funpack"

// ARTIFACT_PRODUCT_NAME is the runtime binary artifact's fixed leaf name under
// `.funpack/`. The name is project-independent so the derived path is a pure
// function of the project root alone (no project-name interpolation), keeping
// the output path deterministic and free of any machine-specific component.
ARTIFACT_PRODUCT_NAME :: "artifact"

// INDEX_PRODUCT_NAME is the Index Contract `project` record's fixed leaf name
// under `.funpack/`. The `.ndjson` extension names the one-object-per-line
// transport (spec §29 §2); like the artifact name it carries no project-specific
// or machine-specific component.
INDEX_PRODUCT_NAME :: "index.ndjson"

// Build_Product is the pair of byte products a successful build emits, with the
// derived output path each is written to. artifact is the runtime binary
// artifact (emit.odin); index is the Index Contract `project` record NDJSON
// (index_contract.odin). Each path is the §14 `.funpack/` derived location under
// the project root, so the struct carries both the bytes and where they land.
Build_Product :: struct {
	artifact:      string,
	index:         string,
	artifact_path: string,
	index_path:    string,
}

// Build_Error is closed with one arm per way a build refuses before it writes
// any product. Malformed_Tree is a §14 project-tree violation (read_project
// rejected the tree); Compile_Failed is any checked-pipeline floor (parse, gate,
// typecheck, contract, or flatten — the source does not compile); Index_Failed
// is an authored-config read failure projecting the `project` record. Every arm
// maps to the exit-2 outcome — a build that cannot emit both products emits
// neither.
Build_Error :: enum {
	None,
	Malformed_Tree,
	Compile_Failed,
	Index_Failed,
}

// stage_build is the build verb's pure seam: it reads the §14 project tree at
// `root` and projects both emission surfaces from its single source. It runs the
// full checked pipeline through stage_emit for the artifact and through
// read_index_project for the Index Contract NDJSON, returning both byte products
// and their derived `.funpack/` output paths. It writes nothing — the impure
// write is write_build_products' job — so it is a pure function of the tree
// contents: two calls on the same tree return byte-identical products. ANY
// checked-pipeline floor (a compile/gate failure on the source) or a malformed
// tree returns the matching Build_Error and no product, so a source that does
// not compile yields neither the artifact nor the NDJSON.
stage_build :: proc(root: string, allocator := context.allocator) -> (product: Build_Product, err: Build_Error) {
	project, project_err := read_project(root)
	if project_err != .None {
		return Build_Product{}, .Malformed_Tree
	}
	if len(project.sources) == 0 {
		return Build_Product{}, .Malformed_Tree
	}
	artifact, emit_err := emit_tree_artifact(root, project, allocator)
	if emit_err != .None {
		return Build_Product{}, .Compile_Failed
	}
	index, index_err, compiled := read_index_project(root, allocator)
	if index_err != .None {
		return Build_Product{}, .Index_Failed
	}
	if !compiled {
		return Build_Product{}, .Compile_Failed
	}
	return Build_Product {
			artifact      = artifact,
			index         = index,
			artifact_path = build_product_path(root, ARTIFACT_PRODUCT_NAME),
			index_path    = build_product_path(root, INDEX_PRODUCT_NAME),
		},
		.None
}

// emit_tree_artifact drives the project tree's single source through stage_emit,
// reading the per-source inputs the emitter needs from the §14 tree: the source
// bytes, its §15 path-derived module name, the §14 project identity, and the
// entrypoints.fcfg text. It mirrors the index seam's single-source projection —
// the gameplay surface is one source, so the build emits that source's artifact.
// A read failure or any checked-pipeline floor surfaces as the stage_emit error,
// which stage_build maps to Compile_Failed (no artifact).
emit_tree_artifact :: proc(root: string, project: Project, allocator := context.allocator) -> (artifact: string, err: Emit_Error) {
	source := project.sources[0]
	source_bytes, read_err := os.read_entire_file_from_path(source.path, context.temp_allocator)
	if read_err != nil {
		return "", .Parse_Failed
	}
	entrypoint_path, _ := filepath.join({root, "funpack_configs", "entrypoints.fcfg"}, context.temp_allocator)
	entrypoint_bytes, ep_err := os.read_entire_file_from_path(entrypoint_path, context.temp_allocator)
	if ep_err != nil {
		return "", .Entrypoint_Failed
	}
	identity := Project_Identity{name = project.name, version = project.version}
	return stage_emit(string(source_bytes), source.module, identity, string(entrypoint_bytes), allocator)
}

// build_product_path joins the project root, the `.funpack/` derived directory,
// and a product's leaf name into the product's output path. The path is derived
// from the root alone (§14 §1) — no machine-specific or project-name component —
// so two builds of the same tree at the same root resolve the same paths.
build_product_path :: proc(root: string, leaf: string, allocator := context.allocator) -> string {
	path, _ := filepath.join({root, FUNPACK_BUILD_DIR, leaf}, allocator)
	return path
}

// Build_Write_Error is closed with one arm per filesystem failure writing the
// products. Mkdir_Failed is a failure creating the `.funpack/` directory;
// Write_Artifact_Failed / Write_Index_Failed are failures writing the respective
// product. The write is all-or-nothing: a failure writing the second product
// removes the first before returning, so an exit-2 build never leaves a
// partial product set from THIS invocation on disk (§29 §3 — a failed build
// writes neither product).
Build_Write_Error :: enum {
	None,
	Mkdir_Failed,
	Write_Artifact_Failed,
	Write_Index_Failed,
}

// write_build_products writes both products under `.funpack/` (creating the
// directory if absent), overwriting any prior build's products. It is the impure
// write side stage_build deliberately omits: stage_build computes the bytes and
// paths purely, this commits them to disk. The directory is created idempotently
// — an existing `.funpack/` is reused, not an error — so a rebuild overwrites in
// place.
write_build_products :: proc(product: Build_Product, root: string) -> Build_Write_Error {
	build_dir, _ := filepath.join({root, FUNPACK_BUILD_DIR}, context.temp_allocator)
	if mk_err := os.make_directory(build_dir); mk_err != nil && mk_err != os.General_Error.Exist {
		return .Mkdir_Failed
	}
	if write_err := os.write_entire_file(product.artifact_path, transmute([]u8)product.artifact); write_err != nil {
		return .Write_Artifact_Failed
	}
	if write_err := os.write_entire_file(product.index_path, transmute([]u8)product.index); write_err != nil {
		// All-or-nothing: the artifact is already on disk, so a failed index
		// write removes it before reporting — an exit-2 build leaves no
		// partial product set behind.
		os.remove(product.artifact_path)
		return .Write_Index_Failed
	}
	return .None
}
