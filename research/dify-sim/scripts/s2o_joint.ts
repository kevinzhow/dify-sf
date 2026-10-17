// Per-run comparison: real outcome vs the simulator's loss probability for the same four commit times.
import { runOne, wilson } from '../src/runner'
import { loadJoint, s2oJoint } from '../src/calib/s2o_joint'

const SEEDS = Number(process.argv[2] ?? '10')
const all = loadJoint()
for (const [set, rows] of Object.entries(all)) {
  let realLost = 0, simLost = 0, simRuns = 0, agree = 0
  const lines: string[] = []
  for (const [i, row] of rows.entries()) {
    let k = 0
    for (let s = 1; s <= SEEDS; s++) if ((await runOne(s2oJoint(row), 1000 * i + s, { calib: true })).res.flags.M1) k++
    realLost += row.lost ? 1 : 0
    simLost += k
    simRuns += SEEDS
    const simMajority = k * 2 > SEEDS
    if (simMajority === row.lost) agree++
    lines.push(`  run ${String(i).padStart(2)} A ${row.aAdd.toFixed(0)}->${row.aRen.toFixed(0)}  B ${row.bAdd.toFixed(0)}->${row.bRen.toFixed(0)}  real ${row.lost ? 'LOST' : 'ok  '}  sim lost ${k}/${SEEDS}`)
  }
  const [lo, hi] = wilson(simLost, simRuns)
  const [rlo, rhi] = wilson(realLost, rows.length)
  console.log(`${set}: real lost ${realLost}/${rows.length} [${(rlo * 100).toFixed(0)}-${(rhi * 100).toFixed(0)}%]  sim lost ${simLost}/${simRuns} [${(lo * 100).toFixed(0)}-${(hi * 100).toFixed(0)}%]  per-run majority agrees ${agree}/${rows.length}`)
  for (const l of lines) console.log(l)
}
