import { CAL_DIST } from '../runner'
import * as E from '../sim/edits'
import { FIXTURES, newNodeFor } from './fixtures'
import type { Case, Step } from './cases'
import { Run, type RunResult } from '../sim/harness'
import type { LinkCfg } from '../sim/net'

export function specFor(s: Step, kindsInit: Record<string, string>): E.EditSpec {
  switch (s.op) {
    case 'setTitle': return E.set(s.node!, 'title', s.value, 'disjoint')
    case 'setField': return E.set(s.node!, s.path!, s.value, 'disjoint')
    case 'setRef': return E.set(s.node!, 'ref', s.value, 'disjoint')
    case 'moveNode': return E.move(s.node!, s.value.x, s.value.y, 'disjoint')
    case 'removeNode': return E.removeNode(s.node!)
    case 'addNode': return E.addNode(newNodeFor(s.value.kind, s.node!, s.value.x, s.value.y), s.from)
    case 'addEdge': return E.addEdgeSpec(s.from!, s.to!)
    case 'removeEdge': return E.removeEdgeSpec(s.from!, s.to!)
    case 'listInsert':
      if (s.path === 'outputs') return E.addOutput(s.node!, s.value)
      if (s.path === 'variables') return E.addVariable(s.node!, s.value)
      return E.addPrompt(s.node!, s.value)
    case 'listRemove':
      if (s.path === 'outputs') return E.removeOutput(s.node!, s.value)
      return E.removeVariable(s.node!, s.value)
  }
  void kindsInit
  throw new Error('unknown op ' + s.op)
}

export async function runCase(c: Case, seed: number, o: { link?: Partial<LinkCfg>; trace?: boolean; calib?: boolean } = {}): Promise<{ res: RunResult; run: Run }> {
  // calib: the same calibrated link and main-thread latency as the S-series (runner.ts runOne with calib)
  const cal = o.calib ? { link: { upMs: 36, downMs: 36, jitterMs: 20 }, rafDist: CAL_DIST() } : {}
  const r = await Run.create(c.id, seed, { keepServerLog: !!o.trace, ...cal })
  const g = FIXTURES['code-node-basic']!()
  r.seed_(g)
  for (const u of c.users) r.addTab(u, o.link ?? {})
  for (const u of c.users) { r.open(u, 0); await r.waitReady([u]); await r.advance(300) } // sequential like the harness: A is the leader
  await r.waitReady()
  const t0 = r.now + 800
  let last = 0
  const specs: [Step, E.EditSpec][] = c.steps.map((s) => [s, specFor(s, {})])
  for (const [s, spec] of specs) {
    const at = t0 + s.at + (s.at > 0 || c.steps.length > 1 ? r.jitter(c.jitter_ms) : 0)
    last = Math.max(last, at - r.now)
    r.edit(Math.max(at, r.now + 1), s.user, spec, s.open_at !== undefined ? { baseAt: t0 + s.open_at } : {})
  }
  const settle = Number(String(c.settle).replace(/s$/, '')) * 1000
  await r.advance(last + 1000 + settle)
  const res = r.evaluate({ tags: c.tags })
  return { res, run: r }
}

/** Serial single-user reference: the same operations applied one after another by ONE user (no concurrency). Anything that still goes wrong
 *  here is inherent to the operation (e.g. deleting a referenced node leaves a dangling reference), not caused by collaboration. */
export async function runCaseSerial(c: Case, seed: number): Promise<RunResult> {
  const r = await Run.create(c.id + '/serial', seed)
  r.seed_(FIXTURES['code-node-basic']!())
  r.addTab('A')
  r.open('A', 0)
  await r.waitReady()
  const t0 = r.now + 800
  const ordered = [...c.steps].sort((a, b) => a.at - b.at)
  ordered.forEach((s, i) => r.edit(t0 + i * 3000, 'A', specFor(s, {})))
  const settle = Number(String(c.settle).replace(/s$/, '')) * 1000
  await r.advance(ordered.length * 3000 + 1000 + settle)
  return r.evaluate({ serial: true })
}
