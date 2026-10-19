// Run with node or bun and the extracted emoji-mart 5.6.0 dist/main.js path as the first argument.
// The original MIT library provides all expected results, using Dify's pinned data, without a browser.
const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '../..');
const { init, SearchIndex } = require(path.resolve(process.argv[2]));
const data = JSON.parse(fs.readFileSync(path.join(root, 'app/assets/emoji/native.json'), 'utf8'));
const queries = [
  '', ' ', '\t\n', '|,||', 'brain', 'Brain', '  BRAIN  ', 'bra', 'rain', 'smile', 'face', 'hand',
  'red heart', 'heart red', 'red|heart', 'red,heart', 'face face', 'face|face', 'raised-hand',
  'raised-hand-with', 'face_with', 'face-with', 'face-with-hand', 'thumb', '-1', '+1', ':)', ';)',
  ':+1:', '🧠', '👍', '👍🏽', '100', 'flag', 'flag us', 'united states', 'south korea',
  'woman technologist', 'cat dog', 'CAT|dog', 'sunglasses', 'sun glasses', 'man-woman',
  'skin-tone-3', 'xyznevermatches', 'dog,cat, dog', 'hot face', 'face hot', 'a', '1',
];
(async () => {
  // Skip browser-native glyph probing in the headless oracle; index the complete pinned catalog.
  // This changes no search/scoring behavior, and the wrapper still reads skins[0].native.
  await init({data, set: 'apple'});
  const cases = [];
  for (const query of queries) {
    const result = await SearchIndex.search(query);
    cases.push({query, ids: (result || []).map(e => e.id)});
  }
  const sortedIds = Object.keys(data.emojis).sort((a,b) => a.localeCompare(b));
  const output = '{\n  "library": "emoji-mart@5.6.0",\n  "data": "@emoji-mart/data@1.2.1",\n  "nativeGlyphProbe": false,\n'
    + '  "sortedIds": ' + JSON.stringify(sortedIds) + ',\n  "cases": [\n'
    + cases.map(c => '    ' + JSON.stringify(c)).join(',\n') + '\n  ]\n}\n';
  const destination = path.join(root, 'app/test/fixtures/emoji_search_v5_6_0.json');
  fs.mkdirSync(path.dirname(destination), {recursive:true});
  fs.writeFileSync(destination, output);
  console.log(`${cases.length} original-library queries; ${sortedIds.length} collation IDs`);
})();
