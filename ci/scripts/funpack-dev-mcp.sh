#!/usr/bin/env sh
set -eu

# funpack-dev MCP launcher — guarantees the served binary matches current source.
#
# The funpack-dev server runs cmd/funpack/funpack. A prebuilt artifact silently
# drifts behind (or vanishes from under) source edits, so this launcher rebuilds it
# when it is missing or older than any tracked source, then exec's it. An up-to-date
# binary is exec'd as-is, so a steady-state reconnect pays no build cost.
#
# stdout is the JSON-RPC channel: every build line and diagnostic goes to stderr (the
# MCP server log) so nothing can corrupt the protocol stream.

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

bin=cmd/funpack/funpack
src_dirs="cli funpack runtime cmd/funpack"

log() { printf 'funpack-dev-mcp: %s\n' "$*" >&2; }

source_is_newer() {
	[ -n "$(find $src_dirs -name '*.odin' -newer "$bin" -print 2>/dev/null | head -n 1)" ]
}

needs_build=0
if [ ! -x "$bin" ]; then
	log "binary missing — building from source"
	needs_build=1
elif source_is_newer; then
	log "source changed since last build — rebuilding"
	needs_build=1
fi

if [ "$needs_build" = 1 ]; then
	command -v task >/dev/null 2>&1 || { log "'task' not on PATH — cannot build $bin; install go-task or run 'task binary' manually"; exit 1; }
	if ! task binary >&2; then
		log "build failed — refusing to start the MCP server"
		exit 1
	fi
	[ -x "$bin" ] || { log "binary still missing after a clean build — aborting"; exit 1; }
fi

exec "$bin" mcp
