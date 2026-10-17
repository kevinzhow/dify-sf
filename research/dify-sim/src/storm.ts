// Storm workload: N users x 500-node Dify graph, ~2 min of edits (1 edit per 1-2 s per user), three mixes, ground-truth ledger.
import { Run } from './sim/harness'
import { bigGraph } from './sim/graphgen'
import * as E from './sim/edits'
import { Rng } from './sim/rng'
import { finalView, danglingRefs, landed } from './sim/ledger'
import { countDiffs, graphDigest, normalizeGraph } from './sim/normalize'
import type { Tab } from './sim/tab'
import { FAST_ON, type FastOpts } from './sim/fastpath'

export type Mix = 'disjoint' | 'contended' | 'faults' | 'formula'
export type StormCfg = {
  users: number
  nodes: number
  durationS: number
  mix: Mix
  seed: number
  fast?: FastOpts
  observers?: number
  joinStaggerMs?: number
  settleS?: number
  editMinMs?: number
  editMaxMs?: number
  linkMs?: [number, number] // per-user one-way latency range
  trace?: boolean
  dragSteps?: number
  rafDist?: number[]
  panelLagMs?: number
  focus?: number // size of the shared working set (nodes users edit); default = all nodes. Teams usually work on one region of the graph.
  /** mix 'formula': the load model of formal/analytic (NOTES.md section 1): Poisson edits at `lambda` per user per second; with
   *  probability `hotShare` an edit goes to one of `hotNodes` hot nodes, otherwise to a field only this user ever writes.
   *  Hot nodes are typed 40/30/30: same register (everyone writes `title`), same node different fields (each user its own
   *  field), list append (each user adds its own input variable to a code node's `variables` array). No deletes (p_del = 0). */
  lambda?: number
  hotShare?: number
  hotNodes?: number
}
const wall = () => Number(process.hrtime.bigint()) / 1e6
const pct = (a: number[], p: number) => (a.length ? a.slice().sort((x, y) => x - y)[Math.min(a.length - 1, Math.floor((p / 100) * a.length))]! : null)
const hash = (s: string) => { let h = 2166136261; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619) } return h >>> 0 }

export async function runStorm(cfg: StormCfg) {
  const w0 = wall()
  const N = cfg.users
  const r = await Run.create(`storm-${cfg.mix}-${N}`, cfg.seed, { keepServerLog: !!cfg.trace, fast: cfg.fast ?? FAST_ON, rafDist: cfg.rafDist, panelLagMs: cfg.panelLagMs })
  const rng = new Rng(cfg.seed, 'storm')
  const { graph, kinds } = bigGraph(cfg.nodes, 1)
  r.seed_(graph)
  const allIds = graph.nodes.map((n: any) => n.id)
  const region = new Set<string>(cfg.focus ? new Rng(cfg.seed, 'region').shuffle(allIds.filter((_: string, i: number) => kinds[i] !== 'start' && kinds[i] !== 'end')).slice(0, cfg.focus) : allIds)
  const nodeIds = allIds.filter((id: string) => region.has(id))
  const byKind: Record<string, string[]> = {}
  graph.nodes.forEach((n: any, i: number) => { if (region.has(n.id)) (byKind[kinds[i]!] ??= []).push(n.id) })
  for (const k of ['code', 'llm', 'if-else', 'template-transform', 'http-request', 'variable-aggregator']) byKind[k] ??= []
  const posOf = new Map<string, { x: number; y: number }>(graph.nodes.map((n: any) => [n.id, n.position]))

  // ------------------------------------------------------------- users, tabs, links
  const users = Array.from({ length: N }, (_, i) => `U${i}`)
  const cur: Record<string, Tab> = {}
  const gen: Record<string, number> = {}
  const heavy = new Set<string>()
  const linkFor = (u: string) => {
    const [a, b] = cfg.linkMs ?? [10, 40]
    const base = rng.range(a, b)
    if (cfg.mix === 'faults' && heavy.has(u)) return { upMs: rng.range(200, 400), downMs: rng.range(200, 400), jitterMs: 40, loss: 0.05 }
    return { upMs: base, downMs: base, jitterMs: 3 }
  }
  if (cfg.mix === 'faults') for (const u of users) if (rng.chance(0.1)) heavy.add(u)
  const spawn = (u: string, atMs: number) => {
    gen[u] = (gen[u] ?? 0) + 1
    const name = gen[u] === 1 ? u : `${u}.${gen[u]}`
    const t = r.addTab(name, linkFor(u), u)
    cur[u] = t
    r.open(name, atMs)
    return t
  }
  const stagger = cfg.joinStaggerMs ?? 150
  users.forEach((u, i) => spawn(u, i * stagger))
  const observerNames = users.slice(0, Math.min(cfg.observers ?? 3, N)).map((u) => u)
  r.observe(...observerNames)
  if (process.env.SIM_PROGRESS) process.stderr.write(`[progress] joining ${N} users\n`)
  await r.waitReady(users, 900_000)
  if (process.env.SIM_PROGRESS) process.stderr.write(`[progress] ready wall=${((wall() - w0) / 1000).toFixed(0)}s rss=${Math.round(process.memoryUsage().rss / 1e6)}MB\n`)
  await r.advance(2000)
  const readyAt = r.now
  if (process.env.SIM_PROGRESS) {
    const iv = 5000
    for (let tt = readyAt + iv; tt < readyAt + cfg.durationS * 1000 + (cfg.settleS ?? 45) * 1000; tt += iv) r.sim.at(tt, () => process.stderr.write(`[progress] v=${((tt - readyAt) / 1000).toFixed(0)}s wall=${((wall() - w0) / 1000).toFixed(0)}s rss=${Math.round(process.memoryUsage().rss / 1e6)}MB heap=${Math.round(process.memoryUsage().heapUsed / 1e6)}MB ab=${Math.round(process.memoryUsage().arrayBuffers / 1e6)}MB wasm=${Math.round(((globalThis as any).__LORO_WASM?.memory.buffer.byteLength ?? 0) / 1e6)}MB events=${r.sim.stats.events} ledger=${r.world.ledger.entries.length}\n`), null)
  }
  const readyWall = wall() - w0

  // ------------------------------------------------------------- edit plans
  const setKeys: Record<string, string[]> = {
    code: ['title', 'desc', 'code'],
    llm: ['title', 'desc', 'prompt0', 'prompt1', 'temp', 'model'],
    'if-else': ['title', 'desc', 'cond'],
    'template-transform': ['title', 'desc', 'template'],
    'http-request': ['title', 'desc', 'url'],
    'variable-aggregator': ['title', 'desc'],
  }
  const ownedSets: Record<string, [string, string][]> = Object.fromEntries(users.map((u) => [u, []]))
  const ownedNodes: Record<string, string[]> = Object.fromEntries(users.map((u) => [u, []]))
  // hot sets (contended mixes): disjoint from the owned pool conceptually (their fields are never in an owner list)
  const hotSame = rng.fork('hs').shuffle([...byKind['code']!]).slice(0, 20)
  const hotDiff = rng.fork('hd').shuffle([...byKind['llm']!]).slice(0, 20)
  const hotSet = new Set([...hotSame, ...hotDiff])
  graph.nodes.forEach((n: any, i: number) => {
    const k = kinds[i]!
    if (!region.has(n.id) || hotSet.has(n.id)) return
    for (const key of setKeys[k] ?? []) ownedSets[users[hash(n.id + '|' + key) % N]!]!.push([n.id, key])
    if (k !== 'start' && k !== 'end') ownedNodes[users[hash(n.id + '|pos') % N]!]!.push(n.id)
  })
  const counter: Record<string, number> = {}
  const mkValue = (u: string, key: string) => {
    const c = (counter[u] = (counter[u] ?? 0) + 1)
    if (key === 'temp') return Math.round(rng.next() * 100) / 100
    if (key === 'model') return `gpt-${c}-${u}`
    return `${u}-${key}-${c}`
  }
  const insertNodes = [...byKind['code']!, ...byKind['llm']!]
  const planDisjoint = (u: string, uRng: Rng): E.EditSpec => {
    const r0 = uRng.next()
    const c = (counter[u] = (counter[u] ?? 0) + 1)
    if (r0 < 0.18 && ownedNodes[u]!.length) {
      const id = uRng.pick(ownedNodes[u]!)
      const p = posOf.get(id)!
      return E.move(id, p.x + uRng.int(300) - 150, p.y + uRng.int(200) - 100, 'disjoint', cfg.dragSteps ?? 6)
    }
    if (r0 < 0.3) {
      const id = uRng.pick(byKind['code']!)
      return E.addOutput(id, `o_${u}_${c}`)
    }
    if (r0 < 0.36) return E.addVariable(uRng.pick(byKind['code']!), `v_${u}_${c}`, ['n0', 'q'])
    if (r0 < 0.40) return E.addPrompt(uRng.pick(byKind['llm']!), `m_${u}_${c}`)
    const [id, key] = ownedSets[u]!.length ? uRng.pick(ownedSets[u]!) : [uRng.pick(nodeIds), 'title']
    return E.set(id, key, mkValue(u, key), 'disjoint')
  }
  // mix 'formula' (see StormCfg.lambda)
  const fH = cfg.hotNodes ?? 30
  const fHot = rng.fork('formula-hot').shuffle([...byKind['code']!]).slice(0, fH)
  const fSame = fHot.slice(0, Math.round(fH * 0.4)), fDiff = fHot.slice(fSame.length, fSame.length + Math.round(fH * 0.3)), fList = fHot.slice(fSame.length + fDiff.length)
  // one private node per user (never shared), so private edits can only be lost by persistence, never by collision
  const fPrivate = rng.fork('formula-priv').shuffle(nodeIds.filter((id: string) => !fHot.includes(id) && id !== 'start' && id !== 'end' && !(byKind['start'] ?? []).includes(id) && !(byKind['end'] ?? []).includes(id)))
  if (cfg.mix === 'formula' && fPrivate.length < N) throw new Error(`formula mix needs ${N} private nodes, graph has ${fPrivate.length}`)
  const planFormula = (u: string, uRng: Rng): E.EditSpec => {
    const c = (counter[u] = (counter[u] ?? 0) + 1)
    if (uRng.next() >= (cfg.hotShare ?? 0.5)) return E.set(fPrivate[users.indexOf(u)]!, `uf_${u}`, `${u}-p${c}`, 'disjoint')
    const x = uRng.next()
    if (x < 0.4) return E.set(uRng.pick(fSame), 'title', `${u}-t${c}`, 'diff-value')
    if (x < 0.7) return E.set(uRng.pick(fDiff), `uf_${u}`, `${u}-f${c}`, 'disjoint')
    // list append = a real array list (the code node's input variables, synced per index); `outputs` is an object and
    // counts as a same-register field in the formula's model (formal/analytic/NOTES.md section 1)
    return E.addVariable(uRng.pick(fList), `v_${u}_${c}`, ['start', 'q'])
  }
  const planFor = (u: string, uRng: Rng, t: number): E.EditSpec => {
    if (cfg.mix === 'formula') return planFormula(u, uRng)
    if (cfg.mix === 'disjoint') return planDisjoint(u, uRng)
    const x = uRng.next()
    if (x < 0.4) return planDisjoint(u, uRng)
    if (x < 0.7) return E.set(uRng.pick(hotSame), 'desc', `SV-${Math.floor((t - readyAt) / 10_000)}`, 'same-value')
    const c = (counter[u] = (counter[u] ?? 0) + 1)
    return E.set(uRng.pick(hotDiff), 'title', `${u}-t${c}`, 'diff-value')
  }
  const editMin = cfg.editMinMs ?? 1000
  const editMax = cfg.editMaxMs ?? 2000
  const endEdit = readyAt + cfg.durationS * 1000
  const attempts = { total: 0, skippedUi: 0 }
  for (const u of users) {
    const uRng = new Rng(cfg.seed, 'user:' + u)
    let t = readyAt + uRng.range(0, editMax)
    while (t < endEdit) {
      const tt = t
      r.sim.at(tt, () => {
        const tab = cur[u]
        attempts.total++
        if (!tab || tab.dead || !tab.loaded) { attempts.skippedUi++; return }
        tab.flush(r.now)
        const spec = planFor(u, uRng, tt)
        const e = r.world.ledger.perform(tab, spec)
        if (e?.blocked) attempts.skippedUi++
      }, null)
      t += cfg.mix === 'formula' ? -Math.log(1 - uRng.next()) * 1000 / (cfg.lambda ?? 0.1) : uRng.range(editMin, editMax)
    }
  }

  // ------------------------------------------------------------- faults (mix iii)
  const faultLog: { t: number; u: string; kind: string; ms?: number }[] = []
  if (cfg.mix === 'faults') {
    const fRng = new Rng(cfg.seed, 'faults')
    const reopen = (u: string, after: number) => r.sim.at(r.now + after, () => spawn(u, 0), null)
    const doFault = (u: string) => {
      const tab = cur[u]
      if (!tab || tab.dead || !tab.loaded) return
      const x = fRng.next()
      if (x < 0.45) {
        const ms = fRng.range(3000, 20_000)
        faultLog.push({ t: r.now, u, kind: 'disconnect', ms })
        tab.flush(r.now)
        r.world.cutLink(tab, 'down', { httpOffline: true })
        r.sim.at(r.now + ms, () => { if (!tab.dead) r.world.healLink(tab) }, null)
      } else if (x < 0.5) {
        const ms = fRng.range(20_000, 50_000)
        faultLog.push({ t: r.now, u, kind: 'blackhole', ms })
        tab.flush(r.now)
        r.world.cutLink(tab, 'blackhole', { httpOffline: true })
        r.sim.at(r.now + ms, () => { if (!tab.dead) r.world.healLink(tab) }, null)
      } else if (x < 0.75) {
        const ms = fRng.range(5000, 40_000)
        faultLog.push({ t: r.now, u, kind: 'hide', ms })
        tab.setVisibility('hidden')
        r.sim.at(r.now + ms, () => { if (!tab.dead) tab.setVisibility('visible') }, null)
      } else if (x < 0.9) {
        const graceful = fRng.chance(0.67)
        faultLog.push({ t: r.now, u, kind: graceful ? 'close' : 'crash' })
        r.world.closeTab(tab, graceful)
        reopen(u, fRng.range(3000, 10_000))
      } else {
        const ms = 15_000
        faultLog.push({ t: r.now, u, kind: 'lag', ms })
        const old = { ...tab.link.cfg }
        tab.link.cfg.upMs += 300; tab.link.cfg.downMs += 300; tab.link.cfg.loss = 0.05
        r.sim.at(r.now + ms, () => Object.assign(tab.link.cfg, old), null)
      }
    }
    for (const u of users) {
      let t = readyAt + fRng.exp(90_000)
      while (t < endEdit - 10_000) {
        const tt = t
        r.sim.at(tt, () => doFault(u), null)
        t += fRng.exp(90_000)
      }
    }
    for (const frac of [0.25, 0.5, 0.75]) {
      r.sim.at(readyAt + cfg.durationS * 1000 * frac, () => {
        const lead = Object.values(cur).find((t) => !t.dead && t.loaded && t.manager?.getIsLeader())
        if (!lead) return
        faultLog.push({ t: r.now, u: lead.user.id, kind: 'leader-close' })
        const u = lead.user.id
        r.world.closeTab(lead, true)
        reopen(u, 5000)
      }, null)
    }
  }

  // ------------------------------------------------------------- run
  const stormStartWall = wall()
  await r.advance(cfg.durationS * 1000 + (cfg.settleS ?? 45) * 1000)
  const stormWall = wall() - stormStartWall

  // ------------------------------------------------------------- evaluation
  const res = r.evaluate({ cfg: { ...cfg, fast: undefined } }, Object.values(cur).map((t) => t.name))
  const w = r.world
  const draft = r.finalDraft()
  const nd = normalizeGraph(draft.nodes, draft.edges)
  const liveTabs = Object.values(cur).filter((t) => !t.dead && t.loaded)
  const digests = new Map<string, number>()
  let divergentFromDraft = 0
  let totalFieldDiffs = 0
  for (const t of liveTabs) {
    const g = normalizeGraph(t.rf.nodes, t.rf.edges)
    const d = graphDigest(g)
    digests.set(d, (digests.get(d) ?? 0) + 1)
    const c = countDiffs(nd, g)
    if (c) { divergentFromDraft++; totalFieldDiffs += c }
  }
  const draftDigest = graphDigest(nd)
  const ev = w.ledger.evaluate(finalView(draft.nodes, draft.edges), { maxExamples: 12 })
  // The same ledger against the replicas' converged state (all live tabs agree when distinctClientStates == 1): an edit
  // missing there was lost by a collision; one present there but not in the stored draft was not persisted (yet).
  const refTab = liveTabs[0]
  const evTabs = refTab ? w.ledger.evaluate(finalView(refTab.rf.nodes, refTab.rf.edges), { maxExamples: 12 }) : null
  const saveLat: number[] = []
  const visLat: number[] = []
  let neverSaved = 0
  let neverVisible = 0
  const fvFinal = finalView(draft.nodes, draft.edges)
  for (const e of w.ledger.entries) {
    if (e.blocked || !landed(e, fvFinal)) continue
    if (e.saveT !== undefined) saveLat.push(e.saveT - e.t)
    else neverSaved++
    for (const o of observerNames) {
      if (o === e.tab || o === e.user) continue
      const vt = e.visT[o]
      if (vt !== undefined) visLat.push(vt - e.t)
      else neverVisible++
    }
  }
  const cls = ev.byClass
  const get = (c: string) => cls[c] ?? { n: 0, landed: 0, superseded: 0, m1: 0, m2: 0 }
  const dis = get('disjoint')
  const lst = get('list')
  const sv = get('same-value')
  const dv = get('diff-value')
  const tabsAll = w.tabs
  const out = {
    cfg: { users: N, nodes: cfg.nodes, durationS: cfg.durationS, mix: cfg.mix, seed: cfg.seed, focus: cfg.focus ?? null, calibrated: !!cfg.rafDist, lambda: cfg.lambda ?? null, hotShare: cfg.hotShare ?? null, hotNodes: cfg.hotNodes ?? null, linkMs: cfg.linkMs ?? null },
    wall: { readyS: +(readyWall / 1000).toFixed(1), stormS: +(stormWall / 1000).toFixed(1), totalS: +((wall() - w0) / 1000).toFixed(1) },
    virtual: { readyAtMs: Math.round(readyAt), endMs: Math.round(r.now), events: r.sim.stats.events },
    edits: { attempted: attempts.total, performed: ev.n, blockedByOverlay: ev.blocked, skippedNoTab: attempts.skippedUi - ev.blocked, byClass: cls },
    lostDisjointEdits: { n: dis.n + lst.n, lost: dis.m1 + lst.m1, silentOverwritten: dis.m2 + lst.m2, byClass: { disjoint: dis, list: lst } },
    sameValue: { n: sv.n, landed: sv.landed, lost: sv.m1 + sv.m2, superseded: sv.superseded },
    diffValue: { n: dv.n, landed: dv.landed, silentOverwrites: dv.m2, lostOther: dv.m1, superseded: dv.superseded },
    M: res.metrics,
    vsTabs: evTabs ? { byClass: evTabs.byClass, chainLost: (evTabs as any).chainLost ?? {}, examples: (evTabs as any).examples ?? [] } : null,
    // formula mix: every same-register write (target, user, virtual time, value it replaced, value), for window analysis
    titleTrace: cfg.mix === 'formula' ? w.ledger.entries.filter((e) => e.spec.cls === 'diff-value' && !e.blocked).map((e) => [e.tid, e.user, Math.round(e.t), e.before, e.spec.value]) : undefined,
    divergence: { liveTabs: liveTabs.length, differFromDraft: divergentFromDraft, fieldDiffs: totalFieldDiffs, distinctClientStates: digests.size, draftDigest: draftDigest.slice(0, 12) },
    saves: { total: w.server.db.saves.length, ok: w.server.db.saves.filter((s) => s.ok).length, conflict409: w.server.db.saves.filter((s) => !s.ok).length, firstOkAtS: (() => { const f = w.server.db.saves.find((s) => s.ok); return f ? +((f.t - readyAt) / 1000).toFixed(1) : null })(), lastOkAtS: (() => { const f = [...w.server.db.saves].reverse().find((s) => s.ok); return f ? +((f.t - readyAt) / 1000).toFixed(1) : null })() },
    saveLatencyMs: { n: saveLat.length, p50: pct(saveLat, 50), p90: pct(saveLat, 90), p99: pct(saveLat, 99), neverSaved },
    visibilityLatencyMs: { n: visLat.length, p50: pct(visLat, 50), p90: pct(visLat, 90), p99: pct(visLat, 99), neverVisible, observers: observerNames.length },
    dangling: danglingRefs(draft.nodes, draft.edges).length,
    server: w.server.stats,
    http: w.httpStats,
    tabs: {
      total: tabsAll.length,
      uncaught: tabsAll.reduce((a, t) => a + t.stats.uncaught, 0),
      consoleErrors: tabsAll.reduce((a, t) => a + t.stats.consoleErrors, 0),
      rafCallbacks: tabsAll.reduce((a, t) => a + t.stats.rafCallbacks, 0),
      bytesUpMB: +(tabsAll.reduce((a, t) => a + t.stats.bytesUp, 0) / 1e6).toFixed(1),
      ingest: tabsAll.reduce((a, t) => ({ delivered: a.delivered + t.ingestStats.delivered, applied: a.applied + t.ingestStats.applied, pruned: a.pruned + t.ingestStats.pruned }), { delivered: 0, applied: 0, pruned: 0 }),
    },
    faults: faultLog.reduce((a: Record<string, number>, f) => ((a[f.kind] = (a[f.kind] ?? 0) + 1), a), {}),
    examples: ev.examples,
    errors: w.sim.errors.slice(0, 3).map((e) => e.err.slice(0, 300)),
    uncaughtSample: tabsAll.flatMap((t) => t.uncaught).slice(0, 3),
  }
  const fingerprint = {
    draft: draftDigest, tabs: Object.fromEntries(liveTabs.map((t) => [t.name, graphDigest(normalizeGraph(t.rf.nodes, t.rf.edges)).slice(0, 12)])),
    ledger: ev.n + ':' + ev.m1 + ':' + ev.m2, saves: w.server.db.saves.map((s) => `${s.by}:${s.ok}:${Math.round(s.t)}`).join(','),
  }
  return { out, fingerprint, run: r }
}
