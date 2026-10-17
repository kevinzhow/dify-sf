// Calibration replay: take the event order recorded from real browsers (calib/record.py) and replay it in the simulator.
import fs from 'node:fs'
import { Run } from '../sim/harness'
import { baseGraph } from '../sim/graphgen'
import * as E from '../sim/edits'
import { diffGraphs, graphDigest, normalizeGraph } from '../sim/normalize'

type Frame = { t: number; d: string; ev: string; n?: number; bin?: number }
export type Rec = {
  scenario: string; i: number; lat: number; gap: number; raf: number; error?: string
  t_ready: number; marks: Record<string, number>
  draft_before: { hash: string; graph: any }; draft_after: { hash: string; graph: any }
  frames: { A: Frame[]; B: Frame[] }
}
const ms = (s: number) => s * 1000

/** Browser-perspective timeline from the in-page probe (WebSocket.send / message timestamps on each tab's own JS clock; same OS clock for both tabs).
 *  Unlike proxy timestamps it is free of harness (CDP/route) forwarding delays. */
export function timelineJS(rec: any) {
  const win = (tab: 'A' | 'B') => {
    const p = rec.probe[tab]
    const t0 = rec.t_ready * 1000
    const abs = (t: number) => p.origin + t
    const sends = (p.sends as number[][]).filter((x) => x[2] === 1 && x[1] > 1000 && abs(x[0]) >= t0 && abs(x[0]) < t0 + 4000).map((x) => ({ t: abs(x[0]), n: x[1] }))
    const recvs = (p.msgs as number[][]).filter((x) => x[1] > 1000 && abs(x[0]) >= t0 && abs(x[0]) < t0 + 6000).map((x) => ({ t: abs(x[0]), n: x[1] }))
    return { sends, recvs }
  }
  const A = win('A'), B = win('B')
  const delays = (from: typeof A, to: typeof A) => from.sends.map((s) => { const r = to.recvs.find((x) => Math.abs(x.n - s.n) < 64 && x.t >= s.t - 1); return r ? Math.max(0.2, r.t - s.t) : 5 })
  return { A: A.sends.map((x) => x.t), B: B.sends.map((x) => x.t), procA: delays(A, B), procB: delays(B, A) }
}

export function timeline(rec: Rec) {
  if ((rec as any).probe?.A?.sends?.length) { const j = timelineJS(rec); if (j.A.length && j.B.length) return j }
  const isBin = (f: Frame) => f.ev === 'graph_event' && f.bin !== undefined
  const commits = (tab: 'A' | 'B') => rec.frames[tab].filter((f) => f.d === 'up_in' && isBin(f) && f.t >= rec.t_ready).map((f) => ms(f.t))
  const A = commits('A')
  const B = commits('B')
  // server + proxy path delay per graph_event: sender up_out(binary) -> receiver down_in(graph_update binary of the same size)
  const procOf = (from: 'A' | 'B', to: 'A' | 'B') => {
    const out: number[] = []
    const ups = rec.frames[from].filter((f) => f.d === 'up_out' && isBin(f) && f.t >= rec.t_ready)
    const downs = rec.frames[to].filter((f) => f.d === 'down_in' && f.ev === 'graph_update' && f.bin !== undefined && f.t >= rec.t_ready)
    for (const u of ups) {
      const d = downs.find((x) => x.bin === u.bin && x.t >= u.t)
      out.push(d ? ms(d.t - u.t) : 3)
    }
    return out
  }
  return { A, B, procA: procOf('A', 'B'), procB: procOf('B', 'A') }
}

export function outcome(scen: string, graph: any, i: number): string {
  const n = (id: string) => graph.nodes.find((x: any) => x.id === id)?.data
  if (scen === 's1n') return `${n('c1').title === `A-title-${i}` ? 'T' : '-'}${n('c1').desc === `B-desc-${i}` ? 'D' : '-'}`
  if (scen === 's2') return n('c1').title.startsWith('A') ? 'A' : n('c1').title.startsWith('B') ? 'B' : '?'
  if (scen === 's2o' || scen === 's2os') return ['oa', 'ob'].filter((o) => Object.keys(n('c2').outputs).includes(o)).join('+') || '-'
  return '?'
}

export async function replayOne(rec: Rec, seed: number, opt: { rafDist?: number[]; panelLag?: number } = {}) {
  const tl = timeline(rec)
  const scen = rec.scenario
  const r = await Run.create('replay-' + scen, seed)
  r.seed_(baseGraph(4))
  const L = rec.lat
  const link = { upMs: L + 0.2, downMs: L + 0.2, jitterMs: 0 }
  r.addTab('A', link, 'alice')
  r.addTab('B', link, 'bob')
  r.open('A', 0)
  r.open('B', 5)
  await r.waitReady()
  r.world.server.procSeq = { A: [...tl.procA], B: [...tl.procB] } // measured per-message server+proxy delay (host load made it 200+ ms in the real runs)
  if (rec.raf) for (const n of ['A', 'B']) r.tab(n).rafDelayMs = rec.raf
  if (opt.rafDist) for (const n of ['A', 'B']) r.tab(n).rafLatencyDist = opt.rafDist
  if (opt.panelLag) for (const n of ['A', 'B']) r.tab(n).panelLagMs = opt.panelLag
  const tFirst = Math.min(tl.A[0] ?? Infinity, tl.B[0] ?? Infinity)
  const T = r.now + 1000
  const at = (t: number) => T + (t - tFirst)
  const i = rec.i
  const gapOf = (c: number[]) => (c.length >= 2 ? Math.max(0, c[1]! - c[0]!) : 0)
  if (scen === 's1n') {
    r.edit(at(tl.A[0]!), 'A', E.set('c1', 'title', `A-title-${i}`, 'disjoint'))
    r.edit(at(tl.B[0]!), 'B', E.set('c1', 'desc', `B-desc-${i}`, 'disjoint'))
  } else if (scen === 's2') {
    r.edit(at(tl.A[0]!), 'A', E.set('c1', 'title', `A-title-${i}`, 'diff-value'))
    r.edit(at(tl.B[0]!), 'B', E.set('c1', 'title', `B-title-${i}`, 'diff-value'))
  } else {
    r.edit(at(tl.A[0]!), 'A', E.addOutput('c2', 'oa', gapOf(tl.A)))
    r.edit(at(tl.B[0]!), 'B', E.addOutput('c2', 'ob', gapOf(tl.B)))
  }
  await r.advance(T - r.now + 2000 + 14000)
  r.world.tabs.forEach((t) => t.flush(r.now))
  const g = r.world.server.db.graph
  return { outcome: outcome(scen, g, i), norm: normalizeGraph(g.nodes, g.edges), tl, run: r }
}

export async function replayFile(file: string, K: number, only?: string, rafDist?: number[], panelLag?: number) {
  const recs: Rec[] = fs.readFileSync(file, 'utf8').trim().split('\n').map((l) => JSON.parse(l)).filter((r) => !r.error && (!only || r.scenario === only))
  const rows: any[] = []
  for (const rec of recs) {
    const real = outcome(rec.scenario, rec.draft_after.graph, rec.i)
    const dist: Record<string, number> = {}
    let exampleNorm: any = null
    for (let s = 1; s <= K; s++) {
      const o = await replayOne(rec, s, { rafDist, panelLag })
      dist[o.outcome] = (dist[o.outcome] ?? 0) + 1
      if (o.outcome === real && !exampleNorm) exampleNorm = o.norm
    }
    const realNorm = normalizeGraph(rec.draft_after.graph.nodes, rec.draft_after.graph.edges)
    const byteEq = exampleNorm ? graphDigest(realNorm) === graphDigest(exampleNorm) : null
    const diff = exampleNorm && !byteEq ? diffGraphs(realNorm, exampleNorm, 6, 120) : []
    const tl = timeline(rec)
    rows.push({ i: rec.i, real, dist, pReal: (dist[real] ?? 0) / K, lat: rec.lat, gap: rec.gap, dAB_ms: tl.A[0] && tl.B[0] ? Math.round(tl.B[0]! - tl.A[0]!) : null, byteEq, diff })
  }
  return rows
}
