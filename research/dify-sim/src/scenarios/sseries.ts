// Simulator equivalents of the repro/scenarios.py scenarios (same graphs, same user actions, same settle times).
import * as E from '../sim/edits'
import type { Scenario, Params } from './types'
import type { Run } from '../sim/harness'
import { baseGraph } from '../sim/graphgen'
import type { LinkCfg } from '../sim/net'

const T0 = 1000 // "action start" after both tabs are ready; ms offset applied by helpers below

/** open tabs A,B(,C) and wait until the collaboration overlay is gone (harness.Tab.wait_ready) */
async function setup(r: Run, names: string[], p: Params, nodes = 4, link: Partial<LinkCfg> = {}, users?: Record<string, string>) {
  r.seed_(baseGraph(nodes))
  for (const n of names) r.addTab(n, link, users?.[n] ?? n)
  // like the Playwright harness: each tab is opened and fully ready (collaboration overlay gone) before the next one opens, so A is always the leader
  for (const n of names) {
    r.open(n, 0)
    await r.waitReady([n])
    await r.advance(300)
  }
  await r.waitReady(names)
  for (const n of names) if (p.rafDelay) r.tab(n).rafDelayMs = p.rafDelay
}
/** per-action UI commit time: select node + fill + blur take ~200 ms +- noise */
const uiAt = (r: Run, base: number, p: Params) => base + 200 + r.jitter(p.uiSd)
/** time of the SECOND actor relative to the first: empirical distribution measured on real Playwright runs (calib/data/*_lat0.jsonl, first-commit differences) when p.uiDelta is set */
const dB = (r: Run, p: Params, key: 's1n' | 's2o') => (p.uiDelta ? p.uiDelta[key]![r.rng.int(p.uiDelta[key]!.length)]! : r.jitter(p.uiSd) * Math.SQRT2)
const lat = (ms: number): Partial<LinkCfg> => ({ upMs: ms, downMs: ms })

async function s1(r: Run, p: Params, l = 0) {
  await setup(r, ['A', 'B'], p, 4, l ? lat(l) : {})
  const t0 = r.now + T0
  r.edit(uiAt(r, t0, p), 'A', E.set('c1', 'title', 'A-c1', 'disjoint'))
  r.edit(uiAt(r, t0 + 700, p), 'A', E.move('c2', 720, 320, 'disjoint'))
  r.edit(uiAt(r, t0, p), 'B', E.set('c3', 'title', 'B-c3', 'disjoint'))
  r.edit(uiAt(r, t0 + 700, p), 'B', E.move('c4', 1360, 290, 'disjoint'))
  await r.advance(T0 + 1500 + p.settleMs)
}
async function s1n(r: Run, p: Params, l = 0) {
  await setup(r, ['A', 'B'], p, 4, l ? lat(l) : {})
  const t0 = r.now + T0
  const d1 = dB(r, p, 's1n') // = commit(A) - commit(B)
  r.edit(t0 + 1500 + d1, 'A', E.set('c1', 'title', 'A-c1', 'disjoint'))
  r.edit(t0 + 1500, 'B', E.set('c1', 'desc', 'B-desc', 'disjoint'))
  await r.advance(T0 + 1500 + Math.max(0, d1) + 600 + p.settleMs)
}
async function s2(r: Run, p: Params, l = 0) {
  await setup(r, ['A', 'B'], p, 4, l ? lat(l) : {})
  const t0 = r.now + T0
  r.edit(uiAt(r, t0, p), 'A', E.set('c1', 'title', 'A-same', 'diff-value'))
  r.edit(uiAt(r, t0, p), 'B', E.set('c1', 'title', 'B-same', 'diff-value'))
  await r.advance(T0 + 600 + p.settleMs)
}
async function s2o(r: Run, p: Params, l = 0, gap = 0) {
  await setup(r, ['A', 'B'], p, 4, l ? lat(l) : {})
  const t0 = r.now + T0
  const d2 = gap > 0 ? 0 : dB(r, p, 's2o')
  const gp = () => (p.uiDelta ? (p.uiDelta as any).s2o_gap[r.rng.int((p.uiDelta as any).s2o_gap.length)] : 30)
  r.edit(t0 + 1500 + d2, 'A', E.addOutput('c2', 'oa', gp()))
  r.edit(t0 + 1500 + gap, 'B', E.addOutput('c2', 'ob', gp()))
  await r.advance(T0 + 1500 + Math.max(0, d2) + gap + 600 + p.settleMs)
}

export const SSERIES: Scenario[] = [
  { id: 'S1', doc: 'A: rename c1 + drag c2; B: rename c3 + drag c4 (different nodes)', real: '0/20', tags: { rel: 'R5', timing: 'T1', fault: 'F0' }, run: (r, p) => s1(r, p) },
  { id: 'S1L', doc: 'S1 with 400 ms one-way websocket latency', real: '0/20', tags: { rel: 'R5', timing: 'T1', fault: 'F1' }, run: (r, p) => s1(r, p, 400) },
  { id: 'S1N', doc: 'A edits c1.title, B edits c1.desc (same node, different fields)', real: 'M1 3/20', tags: { rel: 'R2', timing: 'T1', fault: 'F0' }, run: (r, p) => s1n(r, p) },
  { id: 'S1NL', doc: 'S1N with 400 ms websocket latency', real: '0/20', tags: { rel: 'R2', timing: 'T1', fault: 'F1' }, run: (r, p) => s1n(r, p, 400) },
  { id: 'S1NR', doc: 'S1N with 250 ms rAF delay on both tabs (busy main thread)', real: 'M1 12/20', tags: { rel: 'R2', timing: 'T1', fault: 'F0+cpu' },
    run: async (r, p) => s1n(r, { ...p, rafDelay: 250 }) },
  { id: 'S2', doc: 'A and B rename the same node title concurrently', real: 'no loss flagged (LWW by design)', tags: { rel: 'R1', timing: 'T1', fault: 'F0' }, run: (r, p) => s2(r, p) },
  { id: 'S2L', doc: 'S2 with 400 ms latency', real: 'M2 20/20', tags: { rel: 'R1', timing: 'T1', fault: 'F1' }, run: (r, p) => s2(r, p, 400) },
  { id: 'S2O', doc: 'A and B each add a different output variable to code node c2', real: 'M1 19/19', tags: { rel: 'R4', timing: 'T1', fault: 'F0' }, run: (r, p) => s2o(r, p) },
  { id: 'S2OL', doc: 'S2O with 400 ms latency', real: 'M1 20/20', tags: { rel: 'R4', timing: 'T1', fault: 'F1' }, run: (r, p) => s2o(r, p, 400) },
  { id: 'S2OS', doc: 'S2O but B starts 3 s after A (control)', real: '0/20', tags: { rel: 'R4', timing: 'T2', fault: 'F0' }, run: (r, p) => s2o(r, p, 0, 3000) },
  { id: 'S2OM', doc: 'S2O but B starts 0.8 s after A', real: '0/20', tags: { rel: 'R4', timing: 'T2', fault: 'F0' }, run: (r, p) => s2o(r, p, 0, 800) },

  { id: 'S3A', doc: 'B hidden while leader A edits+saves; B returns and edits c3', tags: { timing: 'T4', rel: 'R5' }, run: async (r, p) => {
    await setup(r, ['A', 'B'], p)
    const t0 = r.now
    r.at(t0 + 100, () => r.tab('B').setVisibility('hidden'), 'B')
    r.edit(t0 + 1500, 'A', E.set('c1', 'title', 'A-c1', 'disjoint'))
    r.edit(t0 + 9800, 'A', E.move('c2', 720, 300, 'disjoint'))
    r.at(t0 + 18000, () => r.tab('B').setVisibility('visible'), 'B')
    r.edit(t0 + 20200, 'B', E.set('c3', 'title', 'B-c3', 'disjoint'))
    await r.advance(20200 + p.settleMs)
  } },
  { id: 'S3B', doc: 'leader A hidden while B edits; A returns', tags: { timing: 'T4', rel: 'R5' }, run: async (r, p) => {
    await setup(r, ['A', 'B'], p)
    const t0 = r.now
    r.at(t0 + 100, () => r.tab('A').setVisibility('hidden'), 'A')
    r.edit(t0 + 2200, 'B', E.set('c3', 'title', 'B-c3', 'disjoint'))
    r.edit(t0 + 10500, 'B', E.move('c4', 1360, 280, 'disjoint'))
    r.at(t0 + 19000, () => r.tab('A').setVisibility('visible'), 'A')
    await r.advance(22000 + 4000 + p.settleMs / 2)
  } },
  { id: 'S3C', doc: 'stale hash after leader hand-off: A(leader),B,C; A edits+saves, A closes, new leader edits', tags: { timing: 'T4', fault: 'F4' }, run: async (r, p) => {
    await setup(r, ['A', 'B', 'C'], p)
    const t0 = r.now
    r.edit(t0 + 300, 'A', E.set('c1', 'title', 'A-c1', 'disjoint'))
    r.at(t0 + 9300, () => r.world.closeTab(r.tab('A'), true), 'A')
    // the new leader (whoever it is) edits c3 3 s after A left
    r.at(t0 + 12600, () => {
      const lead = ['B', 'C'].map((n) => r.tab(n)).find((t) => t.manager.getIsLeader()) ?? r.tab('B')
      r.world.ledger.perform(lead, E.set('c3', 'title', 'L-c3', 'disjoint'))
    }, null)
    await r.advance(12600 + p.settleMs)
  } },
  { id: 'S3E', doc: 'A edits+saves, A leaves; B (new leader, stale hash) edits and closes 1 s later', tags: { timing: 'T4', fault: 'F4' }, run: async (r, p) => {
    await setup(r, ['A', 'B'], p)
    const t0 = r.now
    r.edit(t0 + 300, 'A', E.set('c1', 'title', 'A-c1', 'disjoint'))
    r.at(t0 + 9300, () => r.world.closeTab(r.tab('A'), true), 'A')
    r.edit(t0 + 12300, 'B', E.set('c3', 'title', 'B-c3', 'disjoint'))
    r.at(t0 + 13300, () => r.world.closeTab(r.tab('B'), true))
    await r.advance(13300 + 4000)
  } },
  { id: 'S10', doc: 'A edits and saves; B (open and visible all along) then edits twice (control)', tags: { timing: 'T2' }, run: async (r, p) => {
    await setup(r, ['A', 'B'], p)
    const t0 = r.now
    r.edit(t0 + 300, 'A', E.set('c1', 'title', 'A-c1', 'disjoint'))
    r.edit(t0 + 9300, 'B', E.set('c3', 'title', 'B-c3', 'disjoint'))
    r.edit(t0 + 10300, 'B', E.set('c4', 'title', 'B-c4', 'disjoint'))
    await r.advance(10300 + p.settleMs)
  } },
  { id: 'S4A', doc: 'follower B loses websocket for 12 s while A edits; B reconnects, then edits', tags: { timing: 'T3', fault: 'F2' }, run: async (r, p) => {
    await setup(r, ['A', 'B'], p)
    const t0 = r.now
    r.at(t0, () => { r.world.cutLink(r.tab('B'), 'down', { httpOffline: true }) })
    r.edit(t0 + 1700, 'A', E.set('c1', 'title', 'A-c1', 'disjoint'))
    r.at(t0 + 11500, () => r.world.healLink(r.tab('B')))
    r.edit(t0 + 21800, 'B', E.set('c3', 'title', 'B-c3', 'disjoint'))
    await r.advance(21800 + p.settleMs)
  } },
  { id: 'S4B', doc: 'B edits (focus already in title field) AFTER its websocket dropped; then reconnects', tags: { timing: 'T3', fault: 'F2' }, run: async (r, p) => {
    await setup(r, ['A', 'B'], p)
    const t0 = r.now
    r.at(t0 + 300, () => r.world.cutLink(r.tab('B'), 'down', { httpOffline: true }))
    r.edit(t0 + 1800, 'B', E.set('c3', 'title', 'B-offline', 'disjoint'), { force: true })
    r.at(t0 + 10300, () => r.world.healLink(r.tab('B')))
    await r.advance(10300 + 18000)
  } },
  { id: 'S4C', doc: 'single user A: edit, websocket drops 1.5 s later (inside debounce), returns 8 s later', tags: { timing: 'T3', fault: 'F2' }, run: async (r, p) => {
    await setup(r, ['A'], p)
    const t0 = r.now
    r.edit(t0 + 300, 'A', E.set('c1', 'title', 'A-c1', 'disjoint'))
    r.at(t0 + 2100, () => r.world.cutLink(r.tab('A'), 'down', { httpOffline: true }))
    r.at(t0 + 10100, () => r.world.healLink(r.tab('A')))
    await r.advance(10100 + 20000)
  } },
  { id: 'S4D', doc: 'leader A drops silently (blackhole) for 60 s right after B edits; B should take over', tags: { timing: 'T3', fault: 'F4' }, run: async (r, p) => {
    await setup(r, ['A', 'B'], p)
    const t0 = r.now
    r.at(t0, () => r.world.cutLink(r.tab('A'), 'blackhole', { httpOffline: true }))
    r.edit(t0 + 1300, 'B', E.set('c3', 'title', 'B-c3', 'disjoint'))
    r.at(t0 + 71000, () => r.world.healLink(r.tab('A')))
    await r.advance(71000 + 25000)
  } },
  { id: 'S5A', doc: 'leader A edits then closes the tab gracefully 0.5 s later', tags: { fault: 'F3', timing: 'T1' }, run: async (r, p) => {
    await setup(r, ['A', 'B'], p)
    const t0 = r.now
    r.edit(t0 + 300, 'A', E.set('c1', 'title', 'A-c1', 'disjoint'))
    r.at(t0 + 800, () => r.world.closeTab(r.tab('A'), true))
    await r.advance(800 + p.settleMs)
  } },
  { id: 'S5B', doc: 'leader A edits then crashes 0.5 s later; B stays open', tags: { fault: 'F3' }, run: async (r, p) => {
    await setup(r, ['A', 'B'], p)
    const t0 = r.now
    r.edit(t0 + 300, 'A', E.set('c1', 'title', 'A-c1', 'disjoint'))
    r.at(t0 + 800, () => r.world.closeTab(r.tab('A'), false))
    await r.advance(800 + 20000)
  } },
  { id: 'S5C', doc: 'FOLLOWER B edits and closes 0.5 s later; leader A idle (then crashes later)', tags: { fault: 'F3' }, run: async (r, p) => {
    await setup(r, ['A', 'B'], p)
    const t0 = r.now
    r.edit(t0 + 300, 'B', E.set('c3', 'title', 'B-c3', 'disjoint'))
    r.at(t0 + 800, () => r.world.closeTab(r.tab('B'), true))
    await r.advance(800 + 20000) // the repro harness observes here (A still open), then crashes A; A's canvas holds an edit the draft lacks
  } },
  { id: 'S5D', doc: 'single user: edit, crash 0.5 s later', tags: { fault: 'F3', users: '1p' }, run: async (r, p) => {
    await setup(r, ['A'], p)
    const t0 = r.now
    r.edit(t0 + 300, 'A', E.set('c1', 'title', 'A-c1', 'disjoint'))
    r.at(t0 + 800, () => r.world.closeTab(r.tab('A'), false))
    await r.advance(800 + 2000)
  } },
  ...(['close', 'reload', 'crash', 'nav', 'wait'] as ('close' | 'reload' | 'crash' | 'nav' | 'wait' | 'spa')[]).map((how, i): Scenario => ({
    id: 'S6' + 'ABCDE'[i], doc: `single user: 4 quick edits then ${how} after 0.3 s`, tags: { users: '1p', fault: how === 'wait' ? 'F0' : 'F3' }, run: async (r, p) => {
      await setup(r, ['A'], p)
      const t0 = r.now
      r.edit(t0 + 300, 'A', E.set('c1', 'title', 'A-c1', 'disjoint'))
      r.edit(t0 + 1000, 'A', E.set('c2', 'title', 'A-c2', 'disjoint'))
      r.edit(t0 + 1700, 'A', E.move('c3', 1040, 360 + 110, 'disjoint'))
      r.edit(t0 + 2400, 'A', E.set('c4', 'title', 'A-c4', 'disjoint'))
      const tEnd = t0 + 2700
      if (how === 'close') r.at(tEnd, () => r.world.closeTab(r.tab('A'), true))
      if (how === 'crash') r.at(tEnd, () => r.world.closeTab(r.tab('A'), false))
      if (how === 'nav') r.at(tEnd, () => r.world.closeTab(r.tab('A'), true)) // repro harness uses page.goto(): a FULL navigation (beforeunload fires), not an SPA route change; ops.navigateAway() (true SPA unmount) is untested against a real browser
      if (how === 'spa') r.at(tEnd, () => r.tab('A').navigateAway())
      if (how === 'reload') {
        r.at(tEnd, () => {
          r.world.closeTab(r.tab('A'), true)
          const t = r.addTab('A2')
          r.sim.after(1000, () => void t.open(r.world.appId), null) // browser reload: new document + JS bundle load before the first GET
        })
      }
      await r.advance(2700 + 3000 + 2000)
    } })),
  { id: 'S6F', doc: 'single user, LARGE workflow (100 code nodes, ≈72 KB JSON): edit one title, close 0.5 s later (keepalive 64 KiB limit)', nodes: 100, tags: { users: '1p', fault: 'F3' }, run: async (r, p) => {
    await setup(r, ['A'], p, 100)
    const t0 = r.now
    r.edit(t0 + 300, 'A', E.set('c1', 'title', 'A-c1', 'disjoint'))
    r.at(t0 + 800, () => r.world.closeTab(r.tab('A'), true))
    await r.advance(800 + 4000)
  } },
  { id: 'S6G', doc: 'single user, 30-node workflow (23 KB): same as S6F (control)', tags: { users: '1p', fault: 'F3' }, run: async (r, p) => {
    await setup(r, ['A'], p, 30)
    const t0 = r.now
    r.edit(t0 + 300, 'A', E.set('c1', 'title', 'A-c1', 'disjoint'))
    r.at(t0 + 800, () => r.world.closeTab(r.tab('A'), true))
    await r.advance(800 + 4000)
  } },
  { id: 'S7A', doc: 'A deletes c2 while B renames c2 and drags c3', tags: { rel: 'R7', timing: 'T1' }, run: async (r, p) => {
    await setup(r, ['A', 'B'], p)
    const t0 = r.now + T0
    r.edit(uiAt(r, t0, p), 'A', E.removeNode('c2'))
    r.edit(uiAt(r, t0, p), 'B', E.set('c2', 'title', 'B-c2', 'struct'))
    r.edit(uiAt(r, t0 + 700, p), 'B', E.set('c3', 'title', 'B-c3', 'disjoint'))
    await r.advance(T0 + 1500 + p.settleMs)
  } },
  { id: 'S7AL', doc: 'S7A with 400 ms latency', tags: { rel: 'R7', timing: 'T1', fault: 'F1' }, run: async (r, p) => {
    await setup(r, ['A', 'B'], p, 4, lat(400))
    const t0 = r.now + T0
    r.edit(uiAt(r, t0, p), 'A', E.removeNode('c2'))
    r.edit(uiAt(r, t0, p), 'B', E.set('c2', 'title', 'B-c2', 'struct'))
    r.edit(uiAt(r, t0 + 700, p), 'B', E.set('c3', 'title', 'B-c3', 'disjoint'))
    await r.advance(T0 + 1500 + p.settleMs)
  } },
  { id: 'S7B', doc: 'single user baseline: delete c4 (end node references it)', tags: { rel: 'R6', users: '1p' }, run: async (r, p) => {
    await setup(r, ['A'], p)
    const t0 = r.now
    r.edit(t0 + 300, 'A', E.removeNode('c4'))
    await r.advance(800 + 12000)
  } },
  { id: 'S8', doc: 'draft changed out-of-band (API) while leader tab open; tab then makes two edits', tags: { users: '1p', timing: 'T2' }, run: async (r, p) => {
    await setup(r, ['A'], p)
    const t0 = r.now
    r.at(t0, () => {
      const db = r.world.server.db
      const g = JSON.parse(JSON.stringify(db.graph))
      g.nodes.find((n: any) => n.id === 'c4').data.title = 'EXT-c4'
      db.post({ graph: g, hash: db.hash, _is_collaborative: false }, 'EXT')
      r.world.ledger.external(E.set('c4', 'title', 'EXT-c4', 'disjoint'), 'EXT', r.now)
    })
    r.edit(t0 + 1500, 'A', E.set('c1', 'title', 'A-c1', 'disjoint'))
    r.edit(t0 + 1500 + 9000, 'A', E.set('c2', 'title', 'A-c2', 'disjoint'))
    await r.advance(1500 + 9000 + p.settleMs)
  } },
  { id: 'S9', doc: 'DSL import (workflow_update broadcast) while B has an edit inside its 5 s debounce window', tags: { timing: 'T2' }, run: async (r, p) => {
    await setup(r, ['A', 'B'], p)
    const t0 = r.now
    r.edit(t0 + 300, 'B', E.set('c3', 'title', 'B-c3', 'disjoint'))
    r.at(t0 + 800, () => {
      const db = r.world.server.db
      const g = JSON.parse(JSON.stringify(db.graph))
      g.nodes.find((n: any) => n.id === 'c4').data.title = 'IMPORTED-c4'
      db.post({ graph: g, hash: db.hash, _is_collaborative: false }, 'IMPORT')
      // a third (UI-less) client emits the same socket event update-dsl-modal.tsx:94 does; everybody in the room receives it
      const ts = r.now
      r.world.server.emitRoom(r.world.appId, 'collaboration_update', { type: 'workflow_update', userId: 'X', data: { appId: r.world.appId, timestamp: ts }, timestamp: ts })
    })
    await r.advance(800 + p.settleMs)
  } },
]
