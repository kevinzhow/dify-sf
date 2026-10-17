import fs from 'node:fs'
const p = JSON.parse(fs.readFileSync(process.argv[2]))
const nodes = new Map(p.nodes.map(n => [n.id, n]))
const parent = new Map()
for (const n of p.nodes) for (const c of n.children||[]) parent.set(c, n.id)
const self = new Map()
p.samples.forEach((id,i)=>self.set(id,(self.get(id)||0)+p.timeDeltas[i]))
const incl = new Map()
for (const [id,t] of self){ const seen=new Set(); let cur=id; while(cur!==undefined){ const n=nodes.get(cur); const k=`${n.callFrame.functionName||'(anon)'} ${n.callFrame.url.split('/').slice(-1)[0]}:${n.callFrame.lineNumber}`; if(!seen.has(k)){seen.add(k); incl.set(k,(incl.get(k)||0)+t)} cur=parent.get(cur) } }
const total=[...self.values()].reduce((a,b)=>a+b,0)
for (const [k,t] of [...incl].sort((a,b)=>b[1]-a[1]).slice(0,45)) console.log((t/1000).toFixed(0).padStart(8),'ms',(100*t/total).toFixed(1).padStart(5)+'%',k)
