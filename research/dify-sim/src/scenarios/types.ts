import type { Run } from '../sim/harness'

export type Scenario = {
  id: string
  doc: string
  /** catalog dimension tags (operation / relation / timing / fault / users) */
  tags?: Record<string, string>
  /** the real-browser result observed in repro/logs, when one exists (for the comparison table) */
  real?: string
  run: (r: Run, p: Params) => Promise<void>
  nodes?: number // size of the code-node chain graph (default 4, like repro/lib/graphs.py)
}
export type Params = {
  uiSd: number // ms: std-dev of "when exactly does a scripted UI action commit" (Playwright scheduling noise) for parallel actions
  settleMs: number
  rafDelay?: number
  /** harness-calibrated environment: A->B end-to-end 76 ms median (36 ms/side +-20 jitter), main-thread latency distribution measured in real Chromium (calib/) */
  calib?: boolean
  uiDelta?: { s1n: number[]; s2o: number[] }
  /** calibrated React render lag of the node panel (World.panelLagMs), calib mode only */
  panelLagMs?: number
}
export const defaultParams = (): Params => ({ uiSd: 50, settleMs: 14_000 })
