// Optional check against the actual Dify TypeScript builder; run with Bun.
import fs from 'node:fs';
import assert from 'node:assert/strict';
const source = fs.readFileSync(process.argv[2], 'utf8');
const creation = source.slice(source.indexOf('let edgeCounter'), source.indexOf('const collectLayout'));
const building = source.slice(source.indexOf('const sortIfElseOutEdges'), source.indexOf('export const getLayoutByELK'));
const extracted = `const DEFAULT_NODE_WIDTH=244, DEFAULT_NODE_HEIGHT=100;
const BlockEnum={IfElse:'if-else',QuestionClassifier:'question-classifier',HumanInput:'human-input'};
${creation}\n${building}
return (nodes, edges) => { edgeCounter=0; return buildPortAwareGraph(nodes, edges); };`;
const transpiled = new Bun.Transpiler({loader: 'ts'}).transformSync(extracted);
const originalBuilder = new Function(transpiled)();
const inputs = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
for (const record of inputs) {
  // JSON transport to the elkjs worker drops undefined optional fields.
  const expected = JSON.parse(JSON.stringify(originalBuilder(record.nodes, record.edges)));
  assert.deepEqual(record.graph.children, expected.elkNodes);
  assert.deepEqual(record.graph.edges, expected.elkEdges);
}
console.log(`Verified graph builder against Dify source for all ${inputs.length} inputs`);
