// Scenario harness: builds a world, drives tabs through a scripted/random schedule, settles, evaluates M1-M5.
import { World, type WorldOpts } from './world'
import type { Tab } from './tab'
import { Rng } from './rng'
import { type EditSpec } from './edits'
import { uiInteractive } from './ops'
import { danglingRefs, finalView, landed, type Entry } from './ledger'
import { countDiffs, diffGraphs, graphDigest, normalizeGraph } from './normalize'
import type { LinkCfg } from './net'

export type RunResult = {
  scenario: string
  seed: number
  params: Record<string, unknown>
  metrics: {
    M1: number // acknowledged edits missing from stored draft (not superseded)
    M2: number // silent overwrites (same target, overwriter had not seen the overwritten value)
    M3: number // live clients whose canvas differs from the stored draft
    M4: number // dangling references in stored draft
    M5: number // edits attempted but not even visible locally
  }
  flags: { M1: boolean; M2: boolean; M3: boolean; M4: boolean; M5: boolean }
  detail: Record<string, any>
}

export class Run {
  world!: World
  rng!: Rng
  tabs = new Map<string, Tab>()
  startedAt = 0
  constructor(public name: string, public seed: number, public opts: Partial<WorldOpts> = {}) {}

  static async create(name: string, seed: number, opts: Partial<WorldOpts> = {}) {
    const r = new Run(name, seed, opts)
    r.world = await World.create({ seed, ...opts })
    r.rng = new Rng(seed, 'run:' + name)
    return r
  }
  get sim() {
    return this.world.sim
  }
  get now() {
    return this.world.sim.now
  }
  tab(name: string) {
    const t = this.tabs.get(name)
    if (!t) throw new Error('no tab ' + name)
    return t
  }
  seed_(graph: any) {
    this.world.seedDraft(graph)
  }
  addTab(name: string, link: Partial<LinkCfg> = {}, userId = name): Tab {
    const t = this.world.newTab(name, userId, link)
    this.tabs.set(name, t)
    return t
  }
  open(name: string, atMs = 0) {
    const t = this.tab(name)
    this.sim.at(this.now + atMs, () => void t.open(this.world.appId), null)
  }
  observe(...names: string[]) {
    for (const n of names) {
      const t = this.tab(n)
      this.world.ledger.observers.set(n, t)
      t.onRfChange = (tt) => this.world.ledger.onObserverChange(tt)
      t.noLazy = true
    }
  }
  async advance(ms: number) {
    await this.sim.run(this.now + ms)
  }
  /** run until all named tabs are interactive (overlay gone) */
  async waitReady(names?: string[], maxMs = 120_000) {
    const ts = (names ?? [...this.tabs.keys()]).map((n) => this.tab(n))
    const t0 = this.now
    while (!ts.every((t) => uiInteractive(t))) {
      if (this.now - t0 > maxMs) throw new Error('tabs not ready: ' + ts.filter((t) => !uiInteractive(t)).map((t) => t.name).join(','))
      await this.advance(50)
    }
    await this.advance(200)
  }
  /** schedule a user edit at absolute virtual time `t` (ms). baseAt = when the user opened the panel / started editing */
  edit(t: number, tabName: string, spec: EditSpec, o: { baseAt?: number; force?: boolean } = {}) {
    const tab = this.tab(tabName)
    if (o.baseAt !== undefined) this.sim.at(o.baseAt, () => this.world.ledger.captureBase(tab, spec), tab)
    this.sim.at(t, () => {
      this.world.ledger.perform(tab, spec, o)
    }, tab)
  }
  at(t: number, fn: () => void, tabName?: string) {
    this.sim.at(t, fn, tabName ? this.tab(tabName) : null)
  }
  jitter(sd: number) {
    return this.rng.normal() * sd
  }

  // ---------------------------------------------------------------------------------------------- evaluation
  finalDraft() {
    const g = this.world.server.db.graph
    return { nodes: g.nodes as any[], edges: g.edges as any[] }
  }
  evaluate(params: Record<string, unknown> = {}, liveTabs?: string[]): RunResult {
    const w = this.world
    for (const t of w.tabs) t.flush(w.sim.now)
    const draft = this.finalDraft()
    const fv = finalView(draft.nodes, draft.edges)
    const ev = w.ledger.evaluate(fv)
    const nd = normalizeGraph(draft.nodes, draft.edges)
    const div: Record<string, number> = {}
    const divEx: Record<string, string[]> = {}
    const live = (liveTabs ?? [...this.tabs.keys()]).map((n) => this.tab(n)).filter((t) => !t.dead && t.loaded)
    for (const t of live) {
      const tg = normalizeGraph(t.rf.nodes, t.rf.edges)
      const c = countDiffs(nd, tg)
      if (c) {
        div[t.name] = c
        divEx[t.name] = diffGraphs(nd, tg, 4)
      }
    }
    const dangling = danglingRefs(draft.nodes, draft.edges)
    const metrics = { M1: ev.m1, M2: ev.m2, M3: Object.keys(div).length, M4: dangling.length, M5: ev.m5 }
    return {
      scenario: this.name,
      seed: this.seed,
      params,
      metrics,
      flags: { M1: metrics.M1 > 0, M2: metrics.M2 > 0, M3: metrics.M3 > 0, M4: metrics.M4 > 0, M5: metrics.M5 > 0 },
      detail: {
        intended: ev.n,
        blocked: ev.blocked,
        examples: ev.examples,
        divergence: div,
        divergenceExamples: divEx,
        dangling: dangling.slice(0, 5),
        saves: w.server.db.saves.map((s) => ({ t: Math.round(s.t), by: s.by, ok: s.ok, nodes: s.nodes })),
        draftDigest: graphDigest(nd).slice(0, 16),
        errors: w.sim.errors.length + w.tabs.reduce((a, t) => a + t.stats.uncaught, 0),
        server: { ...w.server.stats },
      },
    }
  }
}
export type { Entry }
export { landed }
