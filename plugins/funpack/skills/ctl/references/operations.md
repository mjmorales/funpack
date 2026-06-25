# funpack:ctl operations reference

Deep detail behind the funpack:ctl skill: the managed-prefix layout, the platform/asset
matrix, the release contract, brew↔managed reconciliation, and troubleshooting. The
SKILL.md is the day-to-day surface; reach here for the corner cases.

## Managed prefix layout

`$FUNPACK_HOME` (default `~/.funpack`):

```
~/.funpack/
├── versions/
│   ├── 0.10.1/
│   │   ├── funpack          the binary for this version
│   │   └── .meta            key=value: source, tag, platform, sha256
│   └── 0.10.2/
│       ├── funpack
│       └── .meta
├── bin/
│   └── funpack -> ../versions/0.10.2/funpack    active-version symlink
└── .previous                0.10.1   (the rollback target: last displaced active)
```

State is the filesystem — there is no database. The active version is read from the
`bin/funpack` symlink target; installed versions are the `versions/*` dirs; the rollback
target is the one line in `.previous`. This is deliberate: no JSON/jq dependency, and the
state survives any tool that can read a symlink. `_activate` writes the version it
displaces into `.previous`, so `rollback` toggles between the two most-recent actives.

Put `$FUNPACK_HOME/bin` on PATH so `funpack` resolves to the active version. Override the
prefix per-invocation with `FUNPACK_HOME=/some/path funpackctl ...`.

## Platform / asset matrix

The release workflow builds three platform tarballs. Asset name:
`funpack-v<X.Y.Z>-<plat>.tar.gz`, extracting to a dir of the same stem containing
`funpack`, `README.md`, `LICENSE`.

| uname -s / -m | `<plat>` | prebuilt? |
|---|---|---|
| Darwin / arm64 | `macos-arm64` | yes |
| Darwin / x86_64 | `macos-x64` | **no** — build from source (`task binary`) or run arm64 under Rosetta |
| Linux / aarch64 | `linux-arm64` | yes |
| Linux / x86_64 | `linux-x64` | yes |

`funpackctl` refuses (exit 1) rather than fetch a wrong-arch asset for an unsupported
combo, surfacing the build-from-source path.

## Release contract

- Repo: `mjmorales/funpack`. Binary releases are tagged `v<semver>`; the plugin line
  (`plugin-v*`) and the retired MCP line (`funpack-mcp-v*`) are filtered out by tag regex.
- Releases are cut **automatically** from conventional commits on `main` — never tag by
  hand. The newest `v*` by `sort -V` is the update target.
- `funpackctl` prefers `gh` for authenticated, rate-limit-friendly queries and downloads,
  and falls back to the public REST API + `curl` when `gh` is absent.
- The binary self-identifies: `funpack version --json` →
  `{"version":"X.Y.Z","schemas":{"artifact":N,"index":N,"introspect":N}}`. `install`
  cross-checks this against the version it filed the download under and warns on mismatch.
  The committed repo-root `VERSION` file is the compile-time source of that string.

## brew ↔ managed reconciliation

Both can be installed at once; `scan` lists each with its real path. The decisive
question is **PATH order** — `funpack` runs the first match in PATH.

- If the user wants brew to stay the source of truth: `brew upgrade mjmorales/tap/funpack`.
  Rollback/pin are not available this way (brew keeps no old versions).
- If the user wants rollback/pinning: install into the managed prefix and ensure
  `~/.funpack/bin` precedes the brew bin in PATH, or run `funpackctl link <dir>` to drop a
  symlink into an earlier PATH dir (default `~/.local/bin`). Confirm `status` then shows
  the managed version as the on-PATH version.

Never declare an update successful on the strength of the managed active version alone;
instead, run `status` and confirm the **on-PATH** version moved before reporting success.

## Command exit contract

- `0` success.
- `1` operational failure (download failed, version not installed, refused destructive op,
  could not resolve latest release, unsupported platform).
- Mutations are idempotent where it matters: `install <ver>` of an already-cached version
  just re-activates it (pass `--force` to re-download); `update` is a no-op when already
  on latest; `use`/`rollback` are pure symlink swaps.

## Troubleshooting

| Symptom | Check |
|---|---|
| `funpack: command not found` | `doctor` — is `$FUNPACK_HOME/bin` (or a `link` dir) on PATH? |
| dyld `Library not loaded: …libSDL2-2.0.0.dylib` on `run`/`live`/`attach` | the binary links SDL2 at a baked-in Homebrew path; install the provider — macOS `brew install sdl2-compat`, Linux `apt install libsdl2-dev`. The pure verbs (`build`/`check`/`test`) need no SDL2. The loader fails before `main`, so funpack cannot report it itself. |
| `funpack version` shows old version after update | brew/dev build earlier in PATH — `scan`, fix PATH order or `link` |
| download fails for a real tag | platform without a prebuilt asset (Intel macOS), or network/`gh` auth — `doctor` |
| `rollback` errors "no longer installed" | the prior version was `uninstall`ed; `install <ver>` it again |
| version reads as `v?` in `scan` | a dev build predating the `version` verb, or a non-funpack file — expected, not an error |
| corporate proxy / no `gh` | falls back to `curl` against `api.github.com` and `github.com/releases/download` |
