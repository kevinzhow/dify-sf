import { Run, type RunResult } from './sim/harness'
import fs from 'node:fs'
import { defaultParams, type Params, type Scenario } from './scenarios/types'
let _cd: number[] | null = null
export const CAL_DIST = () => (_cd ??= (JSON.parse(fs.readFileSync('out/rafdist_dom.json', 'utf8')) as number[]).sort((a, b) => a - b))

export async function runOne(sc: Scenario, seed: number, params: Partial<Params> = {}, opts: { trace?: boolean } = {}): Promise<{ res: RunResult; run: Run }> {
  const p = { ...defaultParams(), ...params }
  if (p.calib && !p.uiDelta) p.uiDelta = JSON.parse(fs.readFileSync('out/ui_delta.json', 'utf8'))
  const cal = p.calib ? { link: { upMs: 36, downMs: 36, jitterMs: 20 }, rafDist: CAL_DIST(), ...(p.panelLagMs ? { panelLagMs: p.panelLagMs } : {}) } : {}
  const r = await Run.create(sc.id, seed, { keepServerLog: !!opts.trace, ...cal })
  await sc.run(r, p)
  const res = r.evaluate({ ...p })
  return { res, run: r }
}

export function wilson(k: number, n: number, z = 1.96): [number, number] {
  if (n === 0) return [0, 1]
  const p = k / n
  const d = 1 + (z * z) / n
  const c = p + (z * z) / (2 * n)
  const h = z * Math.sqrt((p * (1 - p)) / n + (z * z) / (4 * n * n))
  return [Math.max(0, (c - h) / d), Math.min(1, (c + h) / d)]
}

export type Agg = { scenario: string; runs: number; M: Record<string, number>; counts: Record<string, number>; errors: number; examples: RunResult[] }
export function aggregate(id: string, results: RunResult[]): Agg {
  const M: Record<string, number> = { M1: 0, M2: 0, M3: 0, M4: 0, M5: 0 }
  const counts: Record<string, number> = { M1: 0, M2: 0, M3: 0, M4: 0, M5: 0 }
  let errors = 0
  for (const r of results) {
    for (const k of Object.keys(M)) {
      if ((r.flags as any)[k]) M[k]!++
      counts[k]! += (r.metrics as any)[k]
    }
    errors += r.detail.errors > 0 ? 1 : 0
  }
  return { scenario: id, runs: results.length, M, counts, errors, examples: results.filter((r) => Object.values(r.flags).some(Boolean)).slice(0, 2) }
}
