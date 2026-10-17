// Ground-truth ledger of intended edits + post-hoc evaluation (metrics M1-M5, see catalog/CATALOG.md §1).
import { eqJ, targetId, type EditSpec } from './edits'
import { normalizeGraph, type NGraph } from './normalize'
import type { Tab } from './tab'
import { withForcedUi } from './ops'

export type Entry = {
  id: number
  tab: string
  user: string
  t: number // commit time (virtual ms)
  tBase: number // when the author's base view was captured (panel open)
  spec: EditSpec
  tid: string
  before: any // author's view of the target at tBase
  localOk: boolean // value visible in the author's own canvas right after the edit
  blocked?: string
  saveT?: number // first time a saved draft contained it
  visT: Record<string, number> // observer -> first time visible in its canvas
}

export type FinalView = { nodes: Map<string, any>; edges: Map<string, any> }
export const finalView = (nodes: any[], edges: any[]): FinalView => ({ nodes: new Map(nodes.map((n) => [n.id, n])), edges: new Map(edges.map((e) => [e.id, e])) })

export function landed(e: Entry, v: FinalView): boolean {
  const s = e.spec
  switch (s.kind) {
    case 'set': {
      return eqJ(s.read(v.nodes.get(s.node)), s.value)
    }
    case 'move': {
      const p = s.read(v.nodes.get(s.node))
      return !!p && Math.abs(p.x - s.value.x) < 1e-6 && Math.abs(p.y - s.value.y) < 1e-6
    }
    case 'insert':
    case 'remove':
      return v.nodes.has(s.node) && s.read(v.nodes.get(s.node)) === true
    case 'exists':
      return v.nodes.has(s.node) === s.value
    case 'edge':
      return v.edges.has(s.node) === s.value
  }
}

export class Ledger {
  entries: Entry[] = []
  private seq = 1
  private snapshots = new Map<string, any>() // `${tab}|${tid}` -> base view (pre-captured at openAt)
  pendingSave: Entry[] = []
  observers: Map<string, Tab> = new Map()
  pendingVis = new Map<string, Entry[]>() // observer -> entries not yet seen
  visHorizonMs = 120_000

  captureBase(tab: Tab, spec: EditSpec) {
    const n = tab.rf.nodes.find((x: any) => x.id === spec.node)
    this.snapshots.set(`${tab.name}|${targetId(spec)}`, { t: tab.world.sim.now, v: spec.read(n) })
  }

  /** Perform one user edit through the UI op and record intent. */
  perform(tab: Tab, spec: EditSpec, opts: { baseAt?: number; force?: boolean } = {}): Entry | null {
    const now = tab.world.sim.now
    const tid = targetId(spec)
    const node = tab.rf.nodes.find((x: any) => x.id === spec.node)
    const snap = this.snapshots.get(`${tab.name}|${tid}`)
    this.snapshots.delete(`${tab.name}|${tid}`)
    const before = snap ? snap.v : spec.read(node)
    const tBase = snap ? snap.t : now
    tab.world.tr(tab.name, 'EDIT', `${tid} := ${JSON.stringify(spec.value)}  canvas before: ${tab.world.watchValues(tab)}`)
    const res = opts.force ? withForcedUi(() => spec.apply(tab)) : spec.apply(tab)
    if (!res.ok) {
      const e: Entry = { id: this.seq++, tab: tab.name, user: tab.user.id, t: now, tBase, spec, tid, before, localOk: false, blocked: res.blocked ?? 'unknown', visT: {} }
      this.entries.push(e)
      return e
    }
    const after = tab.rf.nodes.find((x: any) => x.id === spec.node)
    const fv = finalView(tab.rf.nodes, tab.rf.edges)
    void after
    const e: Entry = { id: this.seq++, tab: tab.name, user: tab.user.id, t: now, tBase, spec, tid, before, localOk: false, visT: {} }
    e.localOk = spec.kind === 'move' || spec.key === 'outputs+' ? true : landed(e, fv) // multi-step gestures (drag ~330 ms, add+rename output var) complete after this call
    this.entries.push(e)
    this.pendingSave.push(e)
    for (const [name] of this.observers) {
      if (name === tab.name) continue
      if (!this.pendingVis.has(name)) this.pendingVis.set(name, [])
      this.pendingVis.get(name)!.push(e)
    }
    return e
  }

  /** an edit made outside any tab (REST API / another device): recorded as intent only */
  external(spec: EditSpec, user: string, t: number) {
    const e: Entry = { id: this.seq++, tab: 'EXT', user, t, tBase: t, spec, tid: targetId(spec), before: undefined, localOk: true, visT: {} }
    this.entries.push(e)
    return e
  }

  /** called on every server-side successful draft POST */
  onSave(graph: any, t: number) {
    if (!this.pendingSave.length) return
    const fv = finalView(graph.nodes, graph.edges)
    const rest: Entry[] = []
    for (const e of this.pendingSave) {
      if (e.saveT === undefined && landed(e, fv)) e.saveT = t
      else if (e.saveT === undefined) rest.push(e)
    }
    this.pendingSave = rest
  }

  /** called when an observer tab's canvas changes */
  onObserverChange(tab: Tab) {
    const list = this.pendingVis.get(tab.name)
    if (!list || !list.length) return
    const t = tab.world.sim.now
    const fv = finalView(tab.rf.nodes, tab.rf.edges)
    const rest: Entry[] = []
    for (const e of list) {
      if (landed(e, fv)) e.visT[tab.name] = t
      else if (t - e.t < this.visHorizonMs) rest.push(e)
    }
    this.pendingVis.set(tab.name, rest)
  }

  // ------------------------------------------------------------------------------------------------ evaluation
  evaluate(final: FinalView, opts: { maxExamples?: number } = {}) {
    const byTarget = new Map<string, Entry[]>()
    for (const e of this.entries) {
      if (e.blocked) continue
      if (!byTarget.has(e.tid)) byTarget.set(e.tid, [])
      byTarget.get(e.tid)!.push(e)
    }
    type Agg = { n: number; landed: number; superseded: number; m1: number; m2: number }
    const agg: Record<string, Agg> = {}
    const A = (c: string) => (agg[c] ??= { n: 0, landed: 0, superseded: 0, m1: 0, m2: 0 })
    const examples: any[] = []
    let m1 = 0
    let m2 = 0
    let m5 = 0
    let n = 0
    for (const [tid, ws] of byTarget) {
      ws.sort((a, b) => a.t - b.t || a.id - b.id)
      const lands = ws.map((w) => landed(w, final))
      const anyLanded = lands.some(Boolean)
      for (let i = 0; i < ws.length; i++) {
        const w = ws[i]!
        n++
        const a = A(w.spec.cls ?? 'untagged')
        a.n++
        if (!w.localOk) {
          m5++ // never visible on the author's own canvas: swallowed at the source (M5), not an acknowledged edit
          a.n--
          continue
        }
        if (lands[i]) {
          a.landed++
          continue
        }
        // deliberately superseded: a later write by the same user, or by a user whose base view already contained w's value
        let sup = false
        for (let j = i + 1; j < ws.length && !sup; j++) {
          const w2 = ws[j]!
          if (w2.user === w.user) sup = true
          else if (w.spec.kind === 'set' || w.spec.kind === 'move') {
            if (eqJ(w2.before, w.spec.value)) sup = true
          } else if (w.spec.kind === 'insert' || w.spec.kind === 'remove') {
            // opposite action by someone who saw it
            if (w2.spec.kind !== w.spec.kind && w2.before === true) sup = true
          } else if (w2.spec.value !== w.spec.value) sup = true // exists/edge: later opposite op
        }
        if (sup) {
          a.superseded++
          continue
        }
        if (ws.length > 1 && anyLanded && (w.spec.kind === 'set' || w.spec.kind === 'move')) {
          a.m2++
          m2++
          if (examples.length < (opts.maxExamples ?? 10)) examples.push({ type: 'M2', tid, by: w.user, t: Math.round(w.t), value: w.spec.value })
        } else {
          a.m1++
          m1++
          if (examples.length < (opts.maxExamples ?? 10)) examples.push({ type: 'M1', tid, by: w.user, t: Math.round(w.t), value: w.spec.value })
        }
      }
    }
    // Provenance-chain losses (the analytic model's definition, formal/analytic/NOTES.md): for a register written with
    // unique values, walk back from the final value through each write's `before` (the value its author's view showed);
    // a write not on that chain is lost, even if its author wrote the register again later. Only for 'set' targets.
    const chainLost: Record<string, number> = {}
    for (const [, ws] of byTarget) {
      const sets = ws.filter((w) => w.localOk && w.spec.kind === 'set')
      if (!sets.length) continue
      const byValue = new Map<string, Entry>()
      for (const w of sets) byValue.set(JSON.stringify(w.spec.value), w)
      const onChain = new Set<Entry>()
      let cur = sets.find((w) => landed(w, final))
      while (cur && !onChain.has(cur)) {
        onChain.add(cur)
        cur = byValue.get(JSON.stringify(cur.before))
      }
      for (const w of sets) if (!onChain.has(w)) chainLost[w.spec.cls ?? 'untagged'] = (chainLost[w.spec.cls ?? 'untagged'] ?? 0) + 1
    }
    return { n, m1, m2, m5, byClass: agg, chainLost, examples, blocked: this.entries.filter((e) => e.blocked).length }
  }
}

/** M4: references to missing nodes (value_selector[0]) and edges with missing endpoints in a graph */
export function danglingRefs(nodes: any[], edges: any[]) {
  const ids = new Set(nodes.map((n) => n.id))
  const out: string[] = []
  for (const e of edges) if (!ids.has(e.source) || !ids.has(e.target)) out.push(`edge ${e.id}`)
  const check = (sel: any, where: string) => {
    if (Array.isArray(sel) && sel.length && typeof sel[0] === 'string' && !ids.has(sel[0]) && !['sys', 'env', 'conversation'].includes(sel[0])) out.push(`${where} -> ${sel.join('.')}`)
  }
  for (const n of nodes) {
    const d = n.data ?? {}
    for (const v of d.variables ?? []) {
      if (Array.isArray(v)) check(v, `${n.id}.variables`)
      else check(v?.value_selector, `${n.id}.${v?.variable}`)
    }
    for (const o of Array.isArray(d.outputs) ? d.outputs : []) check(o?.value_selector, `${n.id}.out.${o?.variable}`)
    for (const c of d.cases ?? []) for (const cd of c.conditions ?? []) check(cd.variable_selector, `${n.id}.cond`)
  }
  return out
}

export function normFor(nodes: any[], edges: any[]): NGraph {
  return normalizeGraph(nodes, edges)
}
