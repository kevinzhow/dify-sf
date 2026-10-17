// Failure trace: find the smallest seed that reproduces a metric in a scenario and print the event timeline (virtual ms).
import { SSERIES } from './scenarios/sseries'
import { Run } from './sim/harness'
import { defaultParams } from './scenarios/types'
import * as E from './sim/edits'
import fs from 'node:fs'

const id = process.argv[2]!
const metric = process.argv[3] ?? 'M1'
const maxSeed = Number(process.argv[4] ?? 200)
const sc = SSERIES.find((s) => s.id === id)!
const WATCH: Record<string, any[]> = {
  S1N: [E.set('c1', 'title', ''), E.set('c1', 'desc', '')],
  S1NR: [E.set('c1', 'title', ''), E.set('c1', 'desc', '')],
  S2: [E.set('c1', 'title', '')],
  S2L: [E.set('c1', 'title', '')],
  S2O: [{ node: 'c2', key: 'outputs', read: (n: any) => Object.keys(n?.data?.outputs ?? {}) }],
  S2OL: [{ node: 'c2', key: 'outputs', read: (n: any) => Object.keys(n?.data?.outputs ?? {}) }],
  S3C: [E.set('c3', 'title', '')],
  S4C: [E.set('c1', 'title', '')],
  S5A: [E.set('c1', 'title', '')],
  S5C: [E.set('c3', 'title', '')],
  S6F: [E.set('c1', 'title', '')],
  S8: [E.set('c4', 'title', ''), E.set('c1', 'title', '')],
  S7A: [E.set('c2', 'title', '')],
}
for (let seed = 1; seed <= maxSeed; seed++) {
  const cal = process.env.CAL ? { link: { upMs: 36, downMs: 36, jitterMs: 20 }, rafDist: (JSON.parse(fs.readFileSync('out/rafdist_dom.json', 'utf8')) as number[]).sort((a, b) => a - b) } : {}
  const r = await Run.create(sc.id, seed, { keepServerLog: true, ...cal })
  r.world.watch = (WATCH[id] ?? []).map((s: any) => ({ node: s.node, key: s.key, read: s.read }))
  await sc.run(r, { ...defaultParams() })
  const res = r.evaluate()
  if ((process.env.INVERT ? (res.metrics as any)[metric] === 0 : (res.metrics as any)[metric] > 0)) {
    console.log(`# ${id} seed=${seed} ${metric}=${(res.metrics as any)[metric]}  examples=${JSON.stringify(res.detail.examples)}`)
    const t0 = r.world.ledger.entries[0]?.t ?? 0
    const lines = [
      ...r.world.traceLog.map((x) => ({ t: x.t, s: `${x.tab.padEnd(3)} ${x.kind} ${x.info}` })),
      ...r.world.server.log.filter((x) => x.msg.includes('leader') || x.msg.includes('timeout') || x.msg.includes('disconnect')).map((x) => ({ t: x.t, s: `SRV ${x.msg}` })),
      ...r.world.server.db.saves.map((x) => ({ t: x.t, s: `DB  POST draft by ${x.by} ok=${x.ok} nodes=${x.nodes}` })),
    ].filter((x) => x.t >= t0 - 50).sort((a, b) => a.t - b.t)
    for (const l of lines.slice(0, Number(process.env.TRACE_LINES ?? 60))) console.log(`${(l.t - t0).toFixed(1).padStart(9)} ms  ${l.s}`)
    const g = r.world.server.db.graph
    const n = (nid: string) => g.nodes.find((x: any) => x.id === nid).data
    console.log('FINAL stored draft:', JSON.stringify({ c1: { title: n('c1').title, desc: n('c1').desc }, c2: Object.keys(n('c2').outputs) }))
    break
  }
}
