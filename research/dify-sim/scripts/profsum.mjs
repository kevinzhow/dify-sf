import fs from 'node:fs'
const f = process.argv[2]
const p = JSON.parse(fs.readFileSync(f))
const nodes = new Map(p.nodes.map(n => [n.id, n]))
const self = new Map()
const dt = p.timeDeltas
const total = dt.reduce((a,b)=>a+b,0)
p.samples.forEach((id,i)=>{ self.set(id,(self.get(id)||0)+dt[i]) })
const byFn = new Map()
for (const [id,t] of self){ const n=nodes.get(id); const cf=n.callFrame; const k=`${cf.functionName||'(anon)'} ${cf.url.split('/').slice(-2).join('/')}:${cf.lineNumber}`; byFn.set(k,(byFn.get(k)||0)+t) }
const arr=[...byFn].sort((a,b)=>b[1]-a[1]).slice(0,28)
for (const [k,t] of arr) console.log((t/1000).toFixed(0).padStart(8),'ms',(100*t/total).toFixed(1).padStart(5)+'%',k)
