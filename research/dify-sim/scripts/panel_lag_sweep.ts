// Sweeps the node panel's render lag (panelLagMs) against every real reference that involves a panel write:
// per-run agreement on the joint S2O recordings, and the loss rates of S1N, S1NR, S2O, S2OM, S2OS (repro, 20 runs each).
import { runOne, wilson } from '../src/runner'
import { loadJoint, s2oJoint } from '../src/calib/s2o_joint'
import { SSERIES } from '../src/scenarios/sseries'

const lags = (process.argv[2] ?? '0,100,200,300,500').split(',').map(Number)
const K = Number(process.argv[3] ?? '40')
const joint = loadJoint()
const pct = (k: number, n: number) => { const [lo, hi] = wilson(k, n); return `${k}/${n}[${(lo * 100).toFixed(0)}-${(hi * 100).toFixed(0)}]` }
for (const lag of lags) {
  const parts: string[] = []
  for (const [set, rows] of Object.entries(joint)) {
    let agree = 0
    for (const [i, row] of rows.entries()) {
      let k = 0
      for (let s = 1; s <= 5; s++) if ((await runOne(s2oJoint(row), 1000 * i + s, { calib: true, panelLagMs: lag })).res.flags.M1) k++
      if ((k * 2 > 5) === row.lost) agree++
    }
    parts.push(`${set} agree ${agree}/${rows.length}`)
  }
  for (const id of ['S1N', 'S1NR', 'S2O', 'S2OM', 'S2OS']) {
    const sc = SSERIES.find((s) => s.id === id)!
    let k = 0
    for (let s = 1; s <= K; s++) if ((await runOne(sc, s, { calib: true, panelLagMs: lag })).res.flags.M1) k++
    parts.push(`${id} ${pct(k, K)} (real ${sc.real})`)
  }
  console.log(`panelLag ${lag}: ${parts.join(' | ')}`)
}
