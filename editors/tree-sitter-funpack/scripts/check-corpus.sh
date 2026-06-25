#!/usr/bin/env bash
#
# Drift gate (ADR tree-sitter-funpack-topology): the editor grammar is a SEPARATE
# parser from the Odin compiler frontend, so it can silently drift from
# grammar/*.ebnf. This parses every real source file of each IMPLEMENTED file type in
# the repo and fails if any produces an ERROR or MISSING node. Run it whenever a
# grammar or grammar/*.ebnf changes.
#
# Usage: scripts/check-corpus.sh            # all implemented grammars
#        scripts/check-corpus.sh fun fcfg   # a subset
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # editors/tree-sitter-funpack
REPO="$(cd "$HERE/../.." && pwd)"                          # repo root
TS="$HERE/node_modules/.bin/tree-sitter"

# IMPLEMENTED grammars only (stub dirs are excluded until their grammar lands).
GRAMMARS=("${@:-fun fcfg}")
# shellcheck disable=SC2206
GRAMMARS=(${GRAMMARS[@]})

if [ ! -x "$TS" ]; then
  echo "tree-sitter CLI not found at $TS — run 'npm install' in $HERE" >&2
  exit 2
fi

status=0
for dir in "${GRAMMARS[@]}"; do
  [ -f "$HERE/$dir/grammar.js" ] || { echo "[$dir] no grammar.js — skipped (stub)"; continue; }
  ext="$dir"   # file extension equals the grammar dir name (fun -> *.fun, fcfg -> *.fcfg)
  ( cd "$HERE/$dir" && "$TS" generate >/dev/null 2>&1 ) || { echo "[$dir] generate failed" >&2; status=1; continue; }

  files=0; bad=0; errs=0
  while IFS= read -r f; do
    files=$((files + 1))
    n=$( ( cd "$HERE/$dir" && "$TS" parse "$f" 2>/dev/null ) | grep -cE "ERROR|MISSING")
    if [ "$n" -gt 0 ]; then bad=$((bad + 1)); errs=$((errs + n)); echo "  [$dir] $n  ${f#"$REPO"/}"; fi
  done < <(find "$REPO" \( -path "$REPO/.git" -o -path '*/node_modules' -o -path '*/editors' \) -prune -o -name "*.$ext" -print)

  echo "[$dir] files=$files clean=$((files - bad)) error_files=$bad error_nodes=$errs"
  [ "$bad" -gt 0 ] && status=1
done

[ "$status" -eq 0 ] && echo "drift gate: PASS" || echo "drift gate: FAIL"
exit "$status"
