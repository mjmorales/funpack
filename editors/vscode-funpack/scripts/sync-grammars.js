#!/usr/bin/env node
// Copy the highlights queries from the sibling tree-sitter grammars into this
// extension so the bundled semantic queries stay in lockstep with the single source
// of truth (../tree-sitter-funpack/<id>/queries). The WASM parsers are produced
// separately by `npm run build-wasm` (requires the tree-sitter CLI + docker
// emscripten); see README. Run `npm run sync` after changing a grammar's queries.
const fs = require('fs');
const path = require('path');

const EXT = __dirname.replace(/\/scripts$/, '');
const TS = path.join(EXT, '..', 'tree-sitter-funpack');

for (const id of ['fun', 'fcfg']) {
  const src = path.join(TS, id, 'queries', 'highlights.scm');
  const dstDir = path.join(EXT, 'queries', id);
  fs.mkdirSync(dstDir, { recursive: true });
  fs.copyFileSync(src, path.join(dstDir, 'highlights.scm'));
  console.log(`synced queries/${id}/highlights.scm`);

  const wasm = path.join(EXT, 'wasm', `tree-sitter-${id}.wasm`);
  if (!fs.existsSync(wasm)) {
    console.warn(`  WARNING: ${path.relative(EXT, wasm)} missing — run 'npm run build-wasm'`);
  }
}
