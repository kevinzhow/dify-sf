// Randomised check that  doc.import(whole-history update)  and  doc.importJsonUpdates(missing changes up to the same version)  produce
// identical document state, version vectors and event streams (container paths + `by`). Docs have nested maps and lists like Dify's.
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const pkg = require('loro-crdt/nodejs')
const { LoroDoc, LoroMap, LoroList } = pkg
let seedN = 1
const rnd = () => { seedN = (seedN * 1103515245 + 12345) & 0x7fffffff; return seedN / 0x7fffffff }
const ri = (n) => Math.floor(rnd() * n)
const mkBase = () => {
  const A = new LoroDoc(); A.setPeerId(1n)
  const nm = A.getMap('nodes'); const em = A.getMap('edges')
  for (let i = 0; i < 30; i++) {
    const c = nm.setContainer('n' + i, new LoroMap()).getAttached(); c.set('id', 'n' + i); c.set('position', { x: i, y: i })
    const d = c.setContainer('data', new LoroMap()).getAttached(); d.set('title', 't' + i); d.set('outputs', { a: 1 })
    const l = d.setContainer('variables', new LoroList()).getAttached(); l.insert(0, { v: 'a' }); l.insert(1, { v: 'b' })
    em.set('e' + i, { id: 'e' + i, source: 'n' + i })
  }
  A.commit(); return A
}
const K = 40
let bad = 0, steps = 0
for (let trial = 0; trial < K; trial++) {
  const base = mkBase(); const snap = base.export({ mode: 'snapshot' })
  const P = 4
  const mk = (id) => { const d = new LoroDoc(); d.setPeerId(BigInt(100 + id)); d.import(snap); return d }
  const full = Array.from({ length: P }, (_, i) => mk(i)) // receivers using whole-history blobs
  const delt = Array.from({ length: P }, (_, i) => mk(i)) // same peers, using delta import
  const evF = full.map(() => []), evD = delt.map(() => [])
  full.forEach((d, i) => d.subscribe((e) => evF[i].push(e.by + ':' + e.events.map((x) => x.path.join('/')).sort().join(','))))
  delt.forEach((d, i) => d.subscribe((e) => evD[i].push(e.by + ':' + e.events.map((x) => x.path.join('/')).sort().join(','))))
  // senders are the `full` docs themselves (their state is identical to the corresponding delt doc as long as both receive the same ops)
  const inbox = Array.from({ length: P }, () => [])
  for (let step = 0; step < 60; step++) {
    const i = ri(P)
    const act = rnd(); const ni = ri(30); const pos = rnd() < 0.5
    for (const docs of [full, delt]) {
      const d = docs[i]
      if (act < 0.4) { d.getMap('nodes').get('n' + ni).getAttached().get('data').set('title', 'T' + step + 'p' + i) }
      else if (act < 0.7) { const l = d.getMap('nodes').get('n' + ni).getAttached().get('data').get('variables'); if (pos && l.length > 0) l.delete(0, 1); l.insert(0, { v: 'x' + step }) }
      else d.getMap('nodes').get('n' + ni).getAttached().set('position', { x: step, y: i })
      d.commit()
    }
    // sender i broadcasts whole history to a random subset, delivered later in random order
    const blobF = full[i].export({ mode: 'update' })
    const vv = delt[i].oplogVersion()
    for (let j = 0; j < P; j++) if (j !== i && rnd() < 0.8) inbox[j].push({ blobF, vv, from: i })
    for (let j = 0; j < P; j++) if (inbox[j].length && rnd() < 0.5) {
      const k = ri(inbox[j].length); const m = inbox[j].splice(k, 1)[0]
      full[j].import(m.blobF)
      const json = delt[m.from].exportJsonUpdates(delt[j].oplogVersion(), m.vv)
      delt[j].importJsonUpdates(json); steps++
    }
  }
  for (let j = 0; j < P; j++) for (const m of inbox[j]) { full[j].import(m.blobF); delt[j].importJsonUpdates(delt[m.from].exportJsonUpdates(delt[j].oplogVersion(), m.vv)); steps++ }
  for (let j = 0; j < P; j++) {
    const same = JSON.stringify(full[j].toJSON()) === JSON.stringify(delt[j].toJSON())
    const vvEq = JSON.stringify([...full[j].version().toJSON()]) === JSON.stringify([...delt[j].version().toJSON()])
    const evEq = JSON.stringify(evF[j]) === JSON.stringify(evD[j])
    if (!same || !vvEq || !evEq) { bad++; if (bad < 4) console.log('MISMATCH trial', trial, 'doc', j, { same, vvEq, evEq }) }
  }
}
console.log(`delta-equiv: ${K} trials x 4 docs, ${steps} imports compared, mismatches: ${bad}`)
