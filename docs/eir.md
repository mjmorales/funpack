# eir — repo-local Odin lint CLI

`eir` is a developer tool for **this repo**, not part of the shipped funpack product. It
hosts source-tree lints over the funpack monorepo and lives **off** the funpack
release/binary path: it never defines `FUNPACK_LIVE`, never links SDL, and the funpack
compiler never pulls in the lint host. Its only dependencies are the domain-free `cli/`
framework (the same package `cmd/funpack` composes its command tree through) and the `eir/`
lint-host library — so the build is deterministic and SDL-free, which is the whole point of
a dev tool that runs in CI and locally with no native libraries.

Each lint is a registered subcommand. `dup` — an AST DRY/clone checker — is the first; the
host is a registry, so a second lint is one more registry entry and nothing else.

## Why Odin, not Go

The opening premise was a Go linter on a third-party `tree-sitter-odin` grammar. It was
rejected: it reopens the already-superseded `warden-language-go` decision (the `warden/` Go
tree was deleted and the CI `go` job removed), and an external grammar lags the language —
strictly lower fidelity and the same hand-mirror-drift failure mode a linter exists to
prevent. Odin ships a first-party `core:odin/parser`/`ast`/`tokenizer`, so an Odin tool gets
an authoritative AST and satisfies the repo's Odin-First policy. `eir` is also **not** a
`funpack` subcommand — it is repo tooling, not product.

## Build, run, test

`eir` owns its Taskfiles, flatten-composed into the root by namespace (`eir:*` for the
lint-host library, `cmd-eir:*` for the entry binary). It builds, lints, and tests in CI as a
normal Odin arm.

```sh
task cmd-eir:binary      # compile the dev binary to ./cmd/eir/eir (no SDL)
task eir:test            # lint-host unit tests
task cmd-eir:test        # entry composition/wiring tests

# from a checkout of cmd/eir:
odin build . -out:eir    # equivalent to cmd-eir:binary
```

The binary is not installed on `PATH` by default — build it and invoke the produced
artifact, or wire a personal alias. It is a dev tool, so there is no managed-install story
(contrast `funpack:ctl` for the product binary).

```
eir [command]

Available Commands:
  dup  Report Type-1/Type-2 AST clones in the source tree (DRY checker)
```

## `eir dup` — AST DRY / clone checker

Walks the Odin source tree from an optional `[root]` (default cwd) and reports duplicated AST
subtrees — Type-1 exact and Type-2 alpha-renamed clones — following the same `dup_class`
doctrine the `.fun` declaration gate uses, retargeted to `core:odin/ast`. It is a **report,
not a CI gate**: a found clone is informational and never fails the run (a hard gate would
red-light CI day one against existing debt). It is the sibling, over the Odin implementation
source, of funpack's own `.fun` `dup_class` gate — it does not touch that gate.

```
eir dup [flags] [root]
```

### Flags

| Flag | Default | Effect |
|------|---------|--------|
| `--exclude <globs>` | — | Comma-separated glob list of paths to skip. One flag, not repeatable (the framework rejects a duplicate flag); a multi-pattern exclude rides one comma-split string. Globs use `filepath.match` syntax (no `**`) and match against both the path-relative-to-root and the base name, so a bare name like `corpus` prunes that directory at any depth. A matched directory is pruned, not descended. Trailing slashes are tolerated (`vendor/` ≡ `vendor`). |
| `--min-nodes <int>` | ~30 | Subtree node-count floor; clone classes smaller than this are dropped as noise so trivial shapes never register. |
| `--fold-literals` | off | Collapse every literal to one token so constant-only differences collide. Off by default (precision-first: literals are kept distinct). |
| `--json` | off | Emit the ranked clone classes as byte-stable JSON instead of the human table. |

### Exit contract

`{0, 2}`. `0` always on a successful scan — even when clones are found (it is a report). `2`
only on a usage/path error (an unresolvable `[root]`). A clone is never exit 1 in this
surface. Parse failures are surfaced as a stderr count and the scan reports clones over what
it could read — never a silent drop, never an abort.

### How it detects clones

- **Bottom-up Merkle hash.** Each node's hash is `fnv64a(kind_tag ‖ kept_free_names ‖
  child_hashes)` in one O(nodes) pass, so identical subtrees collide regardless of where
  they sit.
- **Normalization (the `dup_class` doctrine).** *Bound* names — `:=`/`let` bindings, proc
  params, for-iterators, named returns — canonicalize to positional slots, so a rename-only
  copy collides. *Free* names — package-qualified calls, type names, field selectors — keep
  their spelling. Every node is kind-tagged, so distinct shapes cannot collide.
- **Cluster by hash, keep classes with ≥2 instances**, above the `--min-nodes` floor.
- **Maximal-only suppression.** A class wholly contained in a larger class with the same
  instance set is dropped, killing nesting-explosion noise (you see the largest shared
  subtree, not every sub-piece of it).
- **Deterministic.** No map-iteration order reaches output; the report is a pure function of
  the class set, so both renderings are byte-stable run to run.

### Ranking — leverage, not size

Classes are ranked by **dedup-value = `node_count × (instances − 1)`** — the nodes *saved* by
collapsing the class to one definition (every repeat past the first is removable). The
head of the report is the highest-leverage refactor. A second metric, **mass =
`node_count × instances`** (gross duplicated size, every site counted), rides the JSON for
sizing but is never the ranking key — a two-instance giant and a many-instance small class
can share a mass while differing sharply in dedup-value.

Order is `(dedup-value desc, hash asc, first-span asc)`. Distinct classes carry distinct
hashes, so `(dedup-value, hash)` is already a total order; the span tie-break only documents
intent.

### Human report

Aligned table — `rank`, `dedup`, `inst` (site count), `kind` (clone-root node kind), then the
`file:line-line` span of every site (first on the row, the rest on continuation lines aligned
under it). An empty result prints the single line `no clones found`.

```
  rank  dedup  inst  kind         sites
  1     469    8     binary       cmd/funpack/mcp_parity_test.odin:42-75
                                  cmd/funpack/mcp_session_test.odin:28-61
                                  ... (6 more sites)
  2     380    5     proc_lit     runtime/introspect_break_test.odin:292-311
                                  ...
```

### JSON report (`--json`)

A single byte-stable object — leading `schema_version`, then `clone_classes` ranked
identically to the table (so JSON row order matches the table). No map is marshaled, so a
double render over the same class set is byte-identical. An empty result is
`{"schema_version":1,"clone_classes":[]}` (never `null`). No trailing newline beyond the
caller's. The leading `rank`/`dedup_value`/`mass` let an agent pick the highest-leverage
target straight off the head of the array.

```jsonc
{
  "schema_version": 1,
  "clone_classes": [
    {
      "rank": 1,
      "dedup_value": 469,            // node_count * (instances - 1) — ranking key
      "mass": 536,                   // node_count * instances — sizing only
      "node_count": 67,
      "instances": 8,
      "kind": "binary",             // clone-root AST node kind
      "hash": "3a20facb3143752f",   // u64 Merkle hash as zero-padded 16-hex string
      "sites": [
        { "path": "cmd/funpack/mcp_parity_test.odin", "is_test": true, "line_start": 42, "line_end": 75 }
        // ... one record per occurrence
      ]
    }
  ]
}
```

| Field | Meaning |
|-------|---------|
| `schema_version` | Report schema version (`DUP_REPORT_SCHEMA_VERSION`, currently `1`). Read before the classes. |
| `rank` | 1-based position by leverage. |
| `dedup_value` | Nodes saved by collapsing the class to one definition. The ranking key. |
| `mass` | Gross duplicated size (every site counted). Sizing, not ranking. |
| `node_count` | Subtree size of the shared shape. |
| `instances` | Number of duplicate sites. |
| `kind` | AST node kind of the clone root. |
| `hash` | Merkle hash as a zero-padded 16-hex-digit **string** (not a number, so a full u64 survives a consumer's parser without precision loss). |
| `sites[]` | One record per occurrence: `path`, `is_test` (so a consumer can scope production vs test duplication), `line_start`, `line_end`. |

### Acting on a report

Read top-down: the rank-1 class is the largest collapsible shape. The `is_test` flag on each
site lets you separate production duplication from the test-fixture repetition that often
dominates the head of the table (test setup blocks are legitimately repetitive). Pick a
class, hoist the shared subtree into one definition, re-run, and the class disappears from the
report.

## Architecture

Topology deliberately mirrors `cmd/funpack` so it reads identically — an entry `main` that
composes a command tree through the shared `cli/` framework, over a domain library:

| File | Role |
|------|------|
| `cmd/eir/main.odin` | Entry. Composes the root, finalizes it (a programmer-error assert, never a user path), and dispatches; guards the empty-argv launch context so a hostile launcher can't fault before dispatch. |
| `eir/eir_lint.odin` | The lint **host** — `lint_registry` (the closed set of lints in help-render order) and `build_lint_subtree` (registry → `cli.Cli_Command` leaves). The registry is the single source of which lints exist and of each lint's whole CLI shape (name, help, flags, arity, handler). |
| `eir/eir_discover.odin` | Filesystem walk for `.odin` sources: exclude-glob pruning, sorted output (a lint must never depend on directory-read order), test/non-test tagging via the `_test.odin` suffix. |
| `eir/eir_ast.odin` | Loads each discovered file via `core:odin/parser` into a `core:odin/ast` tree with a per-file cache. |
| `eir/eir_dup.odin` | The clone engine: Merkle subtree hash, `dup_class` normalization, clustering, maximal-only suppression. |
| `eir/eir_report.odin` | The report surface — ranked human table and byte-stable JSON. Owns presentation only; re-ranks by leverage, never re-walks ASTs. |

The whole scan (parse cache, parsed trees, borrowed path strings, clone classes, rendered
report) lives in one growing arena freed on return, so a run disposes in a single stroke.

### Adding a lint

Append one `Lint` entry to `lint_registry` in `eir/eir_lint.odin` — name, short/long help,
its local flags, its positional arity, and a `run` handler — and write the handler. The host
and the binary need no change; `eir --help` lists exactly the registered set in declaration
order. `cli/` gains a second consumer, proving its domain-freedom by use.

## Deferred (post-v1)

From the ADR, intentionally not built yet:

- A baseline-ratchet **CI gate** over `task lint` — the right eventual state, but it needs the
  existing debt baselined and a ratchet built first.
- A **Type-3 near-miss** similarity tier, reported separately (adds threshold tuning and lower
  precision, so it stays out of the precision-first v1).
- An **MCP / agent tool surface** so the funpack-author/reviewer agents can query clones
  inline — deferred until the core is proven.
- Additional `eir <lint>` verbs beyond `dup`.
