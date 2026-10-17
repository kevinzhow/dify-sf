// S1N / S1NR driven by the commit-time differences of the very repro runs they are compared with
// (repro/logs/S1N*.jsonl: commit(A) - commit(B) per run), instead of the calibration recordings' distribution.
import fs from 'node:fs'
import { runOne, wilson } from '../src/runner'
import { SSERIES } from '../src/scenarios/sseries'

const K = Number(process.argv[2] ?? '60')
const base = JSON.parse(fs.readFileSync('out/ui_delta.json', 'utf8'))
for (const id of ['S1N', 'S1NR']) {
  const deltas: number[] = []
  for (const line of fs.readFileSync(`../repro/logs/${id}.jsonl`, 'utf8').split('\n')) {
    if (!line.trim()) continue
    const r = JSON.parse(line)
    if (!r.edits) continue
    const t: Record<string, number> = {}
    for (const e of r.edits) t[e.by] = e.t
    if (t.A !== undefined && t.B !== undefined) deltas.push((t.A - t.B) * 1000)
  }
  const sc = SSERIES.find((s) => s.id === id)!
  let k = 0
  for (let s = 1; s <= K; s++) if ((await runOne(sc, s, { calib: true, uiDelta: { ...base, s1n: deltas } })).res.flags.M1) k++
  const [lo, hi] = wilson(k, K)
  console.log(`${id}: ${deltas.length} real deltas (median ${deltas.sort((a, b) => a - b)[deltas.length >> 1].toFixed(0)} ms)  sim M1 ${k}/${K} [${(lo * 100).toFixed(0)}-${(hi * 100).toFixed(0)}%]  real ${sc.real}`)
}
