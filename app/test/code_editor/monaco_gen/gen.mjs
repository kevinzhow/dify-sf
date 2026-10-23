// Regenerates ../monaco_tokens.json: runs monaco-editor 0.52.2's own Monarch compiler and lexer (python, javascript),
// its JSON mode tokenizer and the vs theme's TokenTheme over snippets.mjs. Monaco 0.52.2 is the version Dify vendors
// in web/public/vs. Not part of the app; needs bun or node 20+:
//
//   mkdir /tmp/monaco && curl -sL https://registry.npmjs.org/monaco-editor/-/monaco-editor-0.52.2.tgz | tar -xz -C /tmp/monaco
//   bun test/code_editor/monaco_gen/gen.mjs /tmp/monaco/package/esm/vs test/code_editor/monaco_tokens.json
import { readFileSync, writeFileSync } from 'node:fs';
import snippets from './snippets.mjs';
const [vs, out] = process.argv.slice(2);
const { compile } = await import(`${vs}/editor/standalone/common/monarch/monarchCompile.js`);
const { MonarchTokenizer } = await import(`${vs}/editor/standalone/common/monarch/monarchLexer.js`);
const { TokenTheme } = await import(`${vs}/editor/common/languages/supports/tokenization.js`);
const { vs: vsTheme } = await import(`${vs}/editor/standalone/common/themes.js`);

const stub = 'const monaco_editor_core_exports = { languages: { IndentAction: { None: 0, Indent: 1, IndentOutdent: 2, Outdent: 3 } } };';
function section(file, start, end) {
  const text = readFileSync(`${vs}/${file}`, 'utf8');
  const a = text.indexOf(start), b = text.indexOf(end, a);
  if (a < 0 || b < 0) throw new Error(`markers not found in ${file}`);
  return text.slice(a, b);
}
const ts = new Function(`${stub}\n${section('basic-languages/typescript/typescript.js', '// src/basic-languages/typescript/typescript.ts', 'export {')}\nreturn language;`)();
const py = new Function(`${stub}\n${section('basic-languages/python/python.js', '// src/basic-languages/python/python.ts', 'export {')}\nreturn language;`)();
const js = new Function('tsLanguage', `${section('basic-languages/javascript/javascript.js', 'var conf = tsConf;', 'export {').replace('var conf = tsConf;', '')}\nreturn language;`)(ts);
const jsonTok = new Function(`${section('language/json/jsonMode.js', '// node_modules/jsonc-parser/lib/esm/impl/scanner.js', '// node_modules/jsonc-parser/lib/esm/impl/string-intern.js')}
var createScanner2 = createScanner;
${section('language/json/jsonMode.js', '// src/language/json/tokenization.ts', '// src/language/json/jsonMode.ts')}
return createTokenizationSupport(true);`)();

const languageService = { isRegisteredLanguageId: () => false, getLanguageIdByLanguageName: () => null, getLanguageIdByMimeType: () => null };
const configurationService = { getValue: () => 20000, onDidChangeConfiguration: () => ({ dispose() {} }) };
const monarch = (id, def) => new MonarchTokenizer(languageService, null, id, compile(id, def), configurationService);
const tokenizers = { python: monarch('python', py), javascript: monarch('javascript', js) };

const rules = [{ token: '', foreground: vsTheme.colors['editor.foreground'] }, ...vsTheme.rules];
const theme = TokenTheme.createFromRawTokenTheme(rules, []);
const colorMap = theme.getColorMap();
const color = (type) => {
  const m = theme.match(0, type);
  return { fg: colorMap[(m >>> 15) & 0x1ff].toString().toUpperCase(), fontStyle: (m >>> 11) & 0xf };
};

const result = {};
for (const [lang, list] of Object.entries(snippets)) {
  result[lang] = list.map(([name, text]) => {
    const lines = text.split(/\r\n|\r|\n/);
    const tokenizer = tokenizers[lang];
    let state = tokenizer ? tokenizer.getInitialState() : jsonTok.getInitialState();
    const outLines = lines.map((line, i) => {
      let tokens;
      if (tokenizer) {
        const r = tokenizer.tokenize(line, i < lines.length - 1, state);
        state = r.endState;
        tokens = r.tokens.map((t) => [t.offset, t.type]);
      } else {
        // TokenizationSupportAdapter._toClassicTokens
        const r = jsonTok.tokenize(line, state);
        state = r.endState.equals(state) ? state : r.endState;
        let prev = 0;
        tokens = r.tokens.map((t, j) => {
          let s = j === 0 ? 0 : Math.max(t.startIndex, prev);
          prev = s;
          return [s, t.scopes];
        });
      }
      return tokens.map(([o, t]) => { const c = color(t); return [o, t, c.fg, c.fontStyle]; });
    });
    return { name, text, lines: outLines };
  });
}
writeFileSync(out, JSON.stringify(result, null, 1));
console.log('wrote', out);
process.exit(0);
