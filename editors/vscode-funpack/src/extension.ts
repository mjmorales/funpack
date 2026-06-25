import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';
import { Parser, Language, Query } from 'web-tree-sitter';

// Semantic-token layer. The TextMate grammars colour the lexical surface
// (keywords/strings/numbers/booleans/operators/directives); this layer adds the
// STRUCTURAL distinctions TextMate cannot make — variable vs parameter vs property
// vs function vs method vs type vs constructor — by reusing the tree-sitter grammar
// and its highlights.scm queries. One grammar source for both editors.

const TOKEN_TYPES = ['variable', 'parameter', 'property', 'function', 'method', 'type', 'enumMember', 'namespace'];
const TOKEN_MODS = ['readonly'];
const TYPE_INDEX: Record<string, number> = Object.fromEntries(TOKEN_TYPES.map((t, i) => [t, i]));
const legend = new vscode.SemanticTokensLegend(TOKEN_TYPES, TOKEN_MODS);
const READONLY_BIT = 1 << TOKEN_MODS.indexOf('readonly');

// highlights.scm capture name -> semantic token type (+ readonly). Captures with no
// mapping (keyword/string/number/operator/punctuation/attribute/…) are left to TextMate.
function mapCapture(name: string): { type: string; readonly?: boolean } | undefined {
  switch (name) {
    case 'variable': return { type: 'variable' };
    case 'variable.parameter':
    case 'parameter': return { type: 'parameter' };
    case 'property': return { type: 'property' };
    case 'function':
    case 'function.call': return { type: 'function' };
    case 'function.method':
    case 'function.method.call': return { type: 'method' };
    case 'type':
    case 'type.parameter': return { type: 'type' };
    case 'constructor': return { type: 'enumMember' };
    case 'constant': return { type: 'variable', readonly: true };
    case 'module': return { type: 'namespace' };
    default: return undefined;
  }
}

interface Grammar { lang: Language; query: Query; }

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  await Parser.init({
    locateFile: (name: string) => path.join(context.extensionPath, 'node_modules', 'web-tree-sitter', name),
  });
  const parser = new Parser();

  const grammars: Record<string, Grammar> = {};
  for (const id of ['fun', 'fcfg']) {
    try {
      const lang = await Language.load(path.join(context.extensionPath, 'wasm', `tree-sitter-${id}.wasm`));
      const scm = fs.readFileSync(path.join(context.extensionPath, 'queries', id, 'highlights.scm'), 'utf8');
      grammars[id] = { lang, query: new Query(lang, scm) };
    } catch (err) {
      console.error(`funpack: could not load the ${id} semantic grammar (TextMate highlighting still works):`, err);
    }
  }

  const provider: vscode.DocumentSemanticTokensProvider = {
    provideDocumentSemanticTokens(document) {
      const g = grammars[document.languageId];
      if (!g) return null;
      parser.setLanguage(g.lang);
      const tree = parser.parse(document.getText());
      if (!tree) return null;
      try {
        // Last-wins (matches highlights.scm precedence): keep the last mapped capture
        // per start position, then emit in document order (the builder needs sorted pushes).
        const chosen = new Map<string, { row: number; col: number; len: number; type: number; mods: number }>();
        for (const cap of g.query.captures(tree.rootNode)) {
          const m = mapCapture(cap.name);
          if (!m) continue;
          const n = cap.node;
          if (n.startPosition.row !== n.endPosition.row) continue; // semantic tokens are single-line
          const len = n.endPosition.column - n.startPosition.column;
          if (len <= 0) continue;
          chosen.set(`${n.startPosition.row}:${n.startPosition.column}`, {
            row: n.startPosition.row,
            col: n.startPosition.column,
            len,
            type: TYPE_INDEX[m.type],
            mods: m.readonly ? READONLY_BIT : 0,
          });
        }
        const builder = new vscode.SemanticTokensBuilder(legend);
        for (const t of [...chosen.values()].sort((a, b) => a.row - b.row || a.col - b.col)) {
          builder.push(t.row, t.col, t.len, t.type, t.mods);
        }
        return builder.build();
      } finally {
        tree.delete();
      }
    },
  };

  for (const id of ['fun', 'fcfg']) {
    context.subscriptions.push(
      vscode.languages.registerDocumentSemanticTokensProvider({ language: id }, provider, legend),
    );
  }
}

export function deactivate(): void { /* no-op */ }
