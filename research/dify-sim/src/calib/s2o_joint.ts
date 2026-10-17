// S2O replayed with the joint per-run timings of the real calibration recordings (out/s2o_joint.json, written by
// scripts/s2o_joint.py from calib/data/s2o_*.jsonl): each tab's "add" and "rename" commits happen at the recorded
// times after both tabs are ready. Sampling the start offset and the add->rename gap independently (sseries S2O with
// --calib) loses their correlation; this keeps every run's four times together.
import fs from 'node:fs'
import * as E from '../sim/edits'
import { baseGraph } from '../sim/graphgen'
import type { Scenario } from '../scenarios/types'

export type JointRow = { aAdd: number; aRen: number; bAdd: number; bRen: number; raf: number; lost: boolean }
export const loadJoint = (): Record<string, JointRow[]> => JSON.parse(fs.readFileSync('out/s2o_joint.json', 'utf8'))

export function s2oJoint(row: JointRow, id = 'S2OJ'): Scenario {
  return {
    id,
    doc: 'S2O with one real run\'s add/rename commit times',
    run: async (r) => {
      r.seed_(baseGraph(4))
      for (const n of ['A', 'B']) r.addTab(n, {}, n)
      for (const n of ['A', 'B']) {
        r.open(n, 0)
        await r.waitReady([n])
        await r.advance(300)
      }
      const t0 = r.now
      r.edit(t0 + row.aAdd, 'A', E.addOutput('c2', 'oa', Math.max(1, row.aRen - row.aAdd)))
      r.edit(t0 + row.bAdd, 'B', E.addOutput('c2', 'ob', Math.max(1, row.bRen - row.bAdd)))
      await r.advance(Math.max(row.aRen, row.bRen) + 600 + 8000)
    },
  }
}
