const fs = require('node:fs');
const ELK = require(process.env.ELK_MODULE);
(async () => {
  const records = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const engine = new ELK();
  const output = [];
  for (const item of records) {
    try {
      const graph = await engine.layout(item.graph);
      output.push({id: item.id, nodes: graph.children.map(({id,x,y,width,height}) => ({id,x,y,width,height}))});
    } catch (e) {
      output.push({id: item.id, error: String(e)});
    }
  }
  fs.writeFileSync(process.argv[3], JSON.stringify(output, null, 2) + '\n');
})().catch(e => { console.error(e); process.exitCode = 1; });
