#!/usr/bin/env bash
# funpack-mcp-bin.sh — install / update / uninstall the funpack-mcp server binary
# into the plugin's persistent data dir. This is the *mechanical* half: it resolves
# the target path, maps this machine's platform to the release asset, fetches the
# tarball, and places the binary. The `funpack:mcp` skill is the judgment half that
# drives it and interprets the result for the user.
#
# Why a persistent data dir: ${CLAUDE_PLUGIN_ROOT} (the plugin install dir, where the
# committed wrapper bin/funpack-mcp lives) is EPHEMERAL — Claude Code wipes/replaces
# it on every plugin update, so a binary fetched into bin/ would be lost. ${CLAUDE_PLUGIN_DATA}
# (~/.claude/plugins/data/<plugin-id>/) survives updates and is exported to both the MCP
# child process (the wrapper reads $CLAUDE_PLUGIN_DATA) and the Bash a skill runs. So the
# fetched binary's home is $CLAUDE_PLUGIN_DATA/bin/funpack-mcp.
#
# Subcommands: install | update | uninstall | status | path
set -euo pipefail

# ---------------------------------------------------------------------------
# Config — overridable for testing / forks.
# ---------------------------------------------------------------------------
REPO="${FUNPACK_MCP_REPO:-mjmorales/funpack}"
TAG_PREFIX="funpack-mcp-v"

# ---------------------------------------------------------------------------
# Logging helpers — everything human-readable on stderr except the machine
# value `path` prints to stdout. status/install/etc. emit `key: value` lines.
# ---------------------------------------------------------------------------
log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'funpack-mcp-bin: %s\n' "$*" >&2; exit 1; }
kv()   { printf '%s: %s\n' "$1" "$2"; }

# ---------------------------------------------------------------------------
# Platform map. Two naming conventions diverge here:
#   wrapper-os/arch  (darwin/linux, arm64/amd64) — the committed wrapper's
#                    bundled-binary names (funpack-mcp-<wrapper-os>-<wrapper-arch>)
#                    and the dev fallback target.
#   release-os/arch  (macos/linux, arm64/x64)    — the GitHub release asset names.
# ---------------------------------------------------------------------------
resolve_platform() {
  case "$(uname -s)" in
    Darwin) WRAP_OS=darwin; REL_OS=macos ;;
    Linux)  WRAP_OS=linux;  REL_OS=linux ;;
    *) die "unsupported OS $(uname -s) — only darwin and linux are supported" ;;
  esac
  case "$(uname -m)" in
    arm64 | aarch64) WRAP_ARCH=arm64; REL_ARCH=arm64 ;;
    x86_64 | amd64)  WRAP_ARCH=amd64; REL_ARCH=x64 ;;
    *) die "unsupported arch $(uname -m) — only arm64 and amd64/x86_64 are supported" ;;
  esac
}

# ---------------------------------------------------------------------------
# Target resolution. Preference order:
#   1. $CLAUDE_PLUGIN_DATA/bin/funpack-mcp  — the real, update-surviving home
#      (set inside a plugin session; the wrapper execs this first).
#   2. $FUNPACK_MCP_DATA/bin/funpack-mcp    — explicit dev override.
#   3. <repo>/plugins/funpack/bin/funpack-mcp-<wrapper-os>-<wrapper-arch>
#      — the dev/`task mcp:bundle` per-platform path, IF this script can locate
#        the repo from its own location.
# The binary is a SINGLE file for THIS machine's platform (not per-platform-named),
# except case 3 which targets the existing per-platform dev convention.
# TARGET_KIND records which case we used so callers/output can be explicit.
# ---------------------------------------------------------------------------
resolve_target() {
  if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
    BIN_DIR="${CLAUDE_PLUGIN_DATA}/bin"
    BIN="${BIN_DIR}/funpack-mcp"
    TARGET_KIND="plugin-data"
    return
  fi
  if [ -n "${FUNPACK_MCP_DATA:-}" ]; then
    BIN_DIR="${FUNPACK_MCP_DATA}/bin"
    BIN="${BIN_DIR}/funpack-mcp"
    TARGET_KIND="dev-override"
    return
  fi
  local script_dir repo_bin
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
  # scripts/ sits beside bin/ inside plugins/funpack/.
  repo_bin="$(cd -- "${script_dir}/.." >/dev/null 2>&1 && pwd -P)/bin"
  if [ -d "${repo_bin}" ]; then
    BIN_DIR="${repo_bin}"
    BIN="${BIN_DIR}/funpack-mcp-${WRAP_OS}-${WRAP_ARCH}"
    TARGET_KIND="dev-bundle"
    return
  fi
  die "cannot resolve a target: \$CLAUDE_PLUGIN_DATA unset, \$FUNPACK_MCP_DATA unset, and no plugin bin/ dir found beside this script. Run inside a plugin session, or set \$FUNPACK_MCP_DATA=<dir>."
}

# ---------------------------------------------------------------------------
# Latest released tag. gh first (no API rate limit, honors auth), curl fallback.
# Emits the newest funpack-mcp-v* tag on stdout (caller captures it).
# ---------------------------------------------------------------------------
latest_tag() {
  local tag=""
  if command -v gh >/dev/null 2>&1; then
    tag="$(gh release list --repo "$REPO" --limit 100 --json tagName \
            --jq "[.[].tagName | select(startswith(\"${TAG_PREFIX}\"))] | first // empty" \
            2>/dev/null || true)"
  fi
  if [ -z "$tag" ] && command -v curl >/dev/null 2>&1; then
    # /releases is newest-first; pick the first funpack-mcp-v* tag.
    tag="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=100" 2>/dev/null \
            | grep -o "\"tag_name\": *\"${TAG_PREFIX}[^\"]*\"" \
            | head -1 \
            | sed -E 's/.*"('"${TAG_PREFIX}"'[^"]*)".*/\1/' || true)"
  fi
  [ -n "$tag" ] || die "could not resolve the latest ${TAG_PREFIX}* release from ${REPO} (need gh or curl + network)"
  printf '%s\n' "$tag"
}

installed_version() {
  if [ -f "${BIN}.version" ]; then
    cat "${BIN}.version"
  elif [ -x "$BIN" ]; then
    # Fall back to asking the binary; it prints `funpack-mcp <ver> (...)`.
    "$BIN" version 2>&1 | awk '{print "'"${TAG_PREFIX}"'" $2; exit}' || true
  fi
}

# Compare two funpack-mcp-vX.Y.Z tags numerically. Echoes "newer" if $1 > $2,
# "same" if equal, "older" if $1 < $2. Empty $2 => "newer" (nothing installed).
tag_cmp() {
  local a="${1#"$TAG_PREFIX"}" b="${2#"$TAG_PREFIX"}"
  [ -n "$b" ] || { echo newer; return; }
  [ "$a" = "$b" ] && { echo same; return; }
  # sort -V puts the larger version last.
  local hi
  hi="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -1)"
  [ "$hi" = "$a" ] && echo newer || echo older
}

# ---------------------------------------------------------------------------
# Locate the mcp Go module for the build-from-source fallback (no release asset
# for this platform, e.g. macos/amd64 — an Intel Mac). Order:
#   1. $FUNPACK_MCP_SRC (explicit)
#   2. <repo-root>/mcp relative to this script (plugins/funpack/scripts -> ../../../mcp)
# Echoes the module dir or empty.
# ---------------------------------------------------------------------------
locate_mcp_src() {
  if [ -n "${FUNPACK_MCP_SRC:-}" ] && [ -f "${FUNPACK_MCP_SRC}/go.mod" ]; then
    printf '%s\n' "$FUNPACK_MCP_SRC"; return
  fi
  local script_dir candidate
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
  candidate="$(cd -- "${script_dir}/../../.." >/dev/null 2>&1 && pwd -P)/mcp"
  if [ -f "${candidate}/go.mod" ]; then printf '%s\n' "$candidate"; fi
}

# ---------------------------------------------------------------------------
# Does the release with $1=tag carry an asset named $2? gh first, curl fallback.
# ---------------------------------------------------------------------------
asset_exists() {
  local tag="$1" asset="$2"
  if command -v gh >/dev/null 2>&1; then
    gh release view "$tag" --repo "$REPO" --json assets \
      --jq "any(.assets[].name; . == \"${asset}\")" 2>/dev/null | grep -qx true && return 0
    # gh succeeded but asset absent — only trust a clean gh run; on gh error, fall through.
    gh release view "$tag" --repo "$REPO" --json assets >/dev/null 2>&1 && return 1
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSIL -o /dev/null \
      "https://github.com/${REPO}/releases/download/${tag}/${asset}" 2>/dev/null && return 0
  fi
  return 1
}

# Download asset $2 of tag $1 to file $3. gh first, curl fallback.
download_asset() {
  local tag="$1" asset="$2" dest="$3"
  if command -v gh >/dev/null 2>&1; then
    if gh release download "$tag" --repo "$REPO" --pattern "$asset" \
         --output "$dest" --clobber 2>/dev/null; then
      return 0
    fi
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$dest" \
      "https://github.com/${REPO}/releases/download/${tag}/${asset}" && return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# build-from-source fallback for platforms with no published asset.
# ---------------------------------------------------------------------------
build_from_source() {
  local tag="$1" src
  src="$(locate_mcp_src)"
  if [ -z "$src" ]; then
    die "no release asset for this platform (${REL_OS}-${REL_ARCH}) and the mcp Go module was not found. Set \$FUNPACK_MCP_SRC=<repo>/mcp and ensure Go is installed, or install a funpack-mcp on PATH (e.g. \`go install github.com/${REPO}/mcp@latest\` or a brew tap if one exists)."
  fi
  command -v go >/dev/null 2>&1 \
    || die "no release asset for this platform (${REL_OS}-${REL_ARCH}); found the mcp source at ${src} but Go is not installed. Install Go to build from source, or install a funpack-mcp on PATH."
  log "no published asset for ${REL_OS}-${REL_ARCH} — building from source at ${src}"
  mkdir -p "$BIN_DIR"
  ( cd "$src" && go build -o "$BIN" . ) || die "go build failed in ${src}"
  chmod +x "$BIN"
  printf '%s\n' "$tag" > "${BIN}.version"
  kv source "build-from-source (${src})"
}

# ---------------------------------------------------------------------------
# install — resolve latest, fetch the platform asset (or build from source),
# place it at $BIN, stamp $BIN.version. Idempotent: re-running reinstalls cleanly.
# ---------------------------------------------------------------------------
do_install() {
  resolve_platform
  resolve_target
  local tag asset tmp
  tag="$(latest_tag)"
  # The git tag is the full "funpack-mcp-vX.Y.Z" and the asset is
  # "<tag>-<release-os>-<release-arch>.tar.gz" (the tag already carries the
  # funpack-mcp- prefix — do not prepend it again).
  asset="${tag}-${REL_OS}-${REL_ARCH}.tar.gz"
  mkdir -p "$BIN_DIR"

  if asset_exists "$tag" "$asset"; then
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/funpack-mcp.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT
    log "downloading ${asset} (${tag})"
    download_asset "$tag" "$asset" "${tmp}/asset.tar.gz" \
      || die "download failed for ${asset}"
    tar -xzf "${tmp}/asset.tar.gz" -C "$tmp" \
      || die "could not extract ${asset}"
    # The tarball extracts into a versioned subdir (funpack-mcp-<tag>-<os>-<arch>/)
    # holding the funpack-mcp binary (+ README). Find it rather than assume a flat layout.
    local extracted
    extracted="$(find "$tmp" -type f -name funpack-mcp 2>/dev/null | head -1)"
    [ -n "$extracted" ] || die "extracted ${asset} but found no funpack-mcp binary inside"
    mv "$extracted" "$BIN"
    chmod +x "$BIN"
    printf '%s\n' "$tag" > "${BIN}.version"
    kv source "release-asset (${asset})"
    rm -rf "$tmp"
    trap - EXIT
  else
    # No published asset for this platform (e.g. macos-x64 / Intel Mac).
    build_from_source "$tag"
  fi

  kv target "$BIN"
  kv "target-kind" "$TARGET_KIND"
  kv version "$tag"
  if [ -x "$BIN" ]; then
    kv installed "yes"
    kv "self-reported" "$("$BIN" version 2>&1 | head -1 || echo '?')"
  else
    die "post-install: ${BIN} is not present/executable"
  fi
  log "installed funpack-mcp ${tag} -> ${BIN}"
}

# ---------------------------------------------------------------------------
# update — install only if a newer tag exists (or nothing is installed).
# ---------------------------------------------------------------------------
do_update() {
  resolve_platform
  resolve_target
  local installed latest cmp
  installed="$(installed_version || true)"
  latest="$(latest_tag)"
  cmp="$(tag_cmp "$latest" "$installed")"
  if [ ! -x "$BIN" ] || [ "$cmp" = newer ]; then
    if [ -x "$BIN" ]; then
      log "update: ${installed:-<none>} -> ${latest}"
    else
      log "update: binary missing — installing ${latest}"
    fi
    do_install
  else
    kv target "$BIN"
    kv installed "${installed:-<unknown>}"
    kv latest "$latest"
    kv "update-available" "no"
    log "already current (${installed})"
  fi
}

# ---------------------------------------------------------------------------
# uninstall — remove $BIN and its .version stamp. A brew/go-install funpack-mcp
# on PATH is NOT managed here.
# ---------------------------------------------------------------------------
do_uninstall() {
  resolve_platform
  resolve_target
  local removed=0
  if [ -e "$BIN" ]; then rm -f "$BIN"; removed=1; fi
  if [ -e "${BIN}.version" ]; then rm -f "${BIN}.version"; removed=1; fi
  kv target "$BIN"
  if [ "$removed" -eq 1 ]; then
    kv uninstalled "yes"
    log "removed ${BIN} (+ .version)"
  else
    kv uninstalled "no (nothing to remove)"
  fi
  kv note "a funpack-mcp installed via brew or 'go install' on PATH is not managed by this script"
}

# ---------------------------------------------------------------------------
# status — resolved target, installed/latest versions, update availability,
# presence/executability. Always exit 0; latest may be <unknown> if offline.
# ---------------------------------------------------------------------------
do_status() {
  resolve_platform
  resolve_target
  local installed latest update present exec_ok
  installed="$(installed_version || true)"
  latest="$(latest_tag 2>/dev/null || true)"
  present=no; exec_ok=no
  [ -e "$BIN" ] && present=yes
  [ -x "$BIN" ] && exec_ok=yes
  if [ -z "$latest" ]; then
    update="unknown (could not reach release feed)"
  elif [ "$(tag_cmp "$latest" "$installed")" = newer ]; then
    update=yes
  else
    update=no
  fi
  kv platform "${WRAP_OS}-${WRAP_ARCH} (release asset ${REL_OS}-${REL_ARCH})"
  kv target "$BIN"
  kv "target-kind" "$TARGET_KIND"
  kv present "$present"
  kv executable "$exec_ok"
  kv installed "${installed:-<none>}"
  kv latest "${latest:-<unknown>}"
  kv "update-available" "$update"
  if [ "$exec_ok" = yes ]; then
    kv "self-reported" "$("$BIN" version 2>&1 | head -1 || echo '?')"
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# path — print the resolved binary path on stdout (machine value), exit.
# ---------------------------------------------------------------------------
do_path() {
  resolve_platform
  resolve_target
  printf '%s\n' "$BIN"
}

main() {
  local cmd="${1:-status}"
  case "$cmd" in
    install)   do_install ;;
    update)    do_update ;;
    uninstall) do_uninstall ;;
    status)    do_status ;;
    path)      do_path ;;
    -h | --help | help)
      cat >&2 <<'EOF'
funpack-mcp-bin.sh <install|update|uninstall|status|path>

  install    fetch the latest release asset for this platform (or build from
             source where no asset is published) into $CLAUDE_PLUGIN_DATA/bin
  update     reinstall only if a newer release exists
  uninstall  remove the installed binary + version stamp
  status     report target path, installed/latest versions, update availability
  path       print the resolved binary path (stdout)

Env overrides: FUNPACK_MCP_REPO, FUNPACK_MCP_DATA, FUNPACK_MCP_SRC
EOF
      exit 0
      ;;
    *) die "unknown subcommand '${cmd}' (install|update|uninstall|status|path)" ;;
  esac
}

main "$@"
