// Two users write the same title at a controlled gap g (B at t0+g, A at t0), one-way latency LAT per leg; reports the
// share of runs in which one edit is silently overwritten (M2) or missing (M1). Formula window: |g| < 2*LAT + r.
import { Run } from '../src/sim/harness'
import * as E from '../src/sim/edits'
import { baseGraph } from '../src/sim/graphgen'
import { CAL_DIST } from '../src/runner'

const LAT = Number(process.argv[2] ?? '2000')
const SEEDS = Number(process.argv[3] ?? '6')
const gaps = (process.argv[4] ?? '-6000,-4500,-4100,-3900,-3000,-2000,-1000,-300,0,300,1000,2000,3000,3900,4100,4500,6000').split(',').map(Number)
for (const g of gaps) {
  let lost = 0
  for (let s = 1; s <= SEEDS; s++) {
    const r = await Run.create('pair', 1000 + s, { link: { upMs: LAT, downMs: LAT, jitterMs: 0 }, rafDist: CAL_DIST() })
    r.seed_(baseGraph(4))
    for (const n of ['A', 'B']) r.addTab(n, {}, n)
    for (const n of ['A', 'B']) { r.open(n, 0); await r.waitReady([n]); await r.advance(300) }
    const t0 = r.now + 7000
    r.edit(t0, 'A', E.set('c1', 'title', 'A-title', 'diff-value'))
    r.edit(t0 + g, 'B', E.set('c1', 'title', 'B-title', 'diff-value'))
    await r.advance(7000 + Math.abs(g) + 4 * LAT + 8000)
    const res = r.evaluate({})
    if (res.flags.M1 || res.flags.M2) lost++
  }
  console.log(`g=${String(g).padStart(6)} ms  lost ${lost}/${SEEDS}`)
}
