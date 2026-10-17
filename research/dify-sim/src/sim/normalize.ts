// Canonical projection of a graph for comparison / byte-level hashing.
//   dropped: keys starting with '_' (client-private; Dify strips them before POST, use-nodes-sync-draft.ts:73-77), data.selected,
//            ReactFlow DOM-derived fields (width, height, positionAbsolute, dragging, selected, zIndex, sourcePosition, targetPosition is kept),
//            timestamps/ids are not present in graph JSON.
//   rounded: positions to 3 decimals (float noise).
import { createHash } from 'node:crypto'
import { pyDumps } from './pyjson'

const DROP_NODE = new Set(['width', 'height', 'positionAbsolute', 'dragging', 'selected', 'zIndex', 'resizing'])
const strip = (v: any): any => {
  if (Array.isArray(v)) return v.map(strip)
  if (v && typeof v === 'object') {
    const o: any = {}
    for (const k of Object.keys(v).sort()) {
      if (k.startsWith('_')) continue
      if (v[k] === undefined || v[k] === null) continue // undefined/null/absent are the same for comparison (Loro turns undefined into null)
      o[k] = strip(v[k])
    }
    return o
  }
  return v
}
const r3 = (x: number) => Math.round(x * 1000) / 1000

export type NGraph = { nodes: Record<string, any>; edges: Record<string, any> }

export function normalizeGraph(nodes: any[], edges: any[]): NGraph {
  const ns: Record<string, any> = {}
  for (const n of nodes) {
    if (n?.data?.type === 'start-placeholder') continue
    const o: any = {}
    for (const k of Object.keys(n)) {
      if (DROP_NODE.has(k) || k === 'data') continue
      if (n[k] === undefined) continue
      o[k] = strip(n[k])
    }
    if (o.position) o.position = { x: r3(o.position.x), y: r3(o.position.y) }
    const data = { ...n.data }
    delete data.selected
    o.data = strip(data)
    ns[n.id] = o
  }
  const es: Record<string, any> = {}
  for (const e of edges) {
    const o: any = {}
    for (const k of Object.keys(e)) {
      if (e[k] === undefined || k === 'zIndex') continue
      o[k] = strip(e[k])
    }
    if (o.data) delete o.data.isInIteration, delete o.data.isInLoop
    es[e.id] = o
  }
  return { nodes: ns, edges: es }
}
export const graphDigest = (g: NGraph): string => createHash('sha256').update(pyDumps(g)).digest('hex')

/** list the differing (node.path) / edges between two normalized graphs (bounded) */
export function diffGraphs(a: NGraph, b: NGraph, limit = 20, W = 60): string[] {
  const out: string[] = []
  const walk = (x: any, y: any, p: string) => {
    if (out.length >= limit) return
    if (JSON.stringify(x) === JSON.stringify(y)) return
    if (x && y && typeof x === 'object' && typeof y === 'object' && !Array.isArray(x) && !Array.isArray(y)) {
      for (const k of new Set([...Object.keys(x), ...Object.keys(y)])) walk(x[k], y[k], p + '.' + k)
    } else out.push(`${p}: ${JSON.stringify(x)?.slice(0, W)} != ${JSON.stringify(y)?.slice(0, W)}`)
  }
  for (const id of new Set([...Object.keys(a.nodes), ...Object.keys(b.nodes)])) {
    if (!a.nodes[id]) out.push(`node ${id}: missing in A`)
    else if (!b.nodes[id]) out.push(`node ${id}: missing in B`)
    else walk(a.nodes[id], b.nodes[id], 'node ' + id)
  }
  for (const id of new Set([...Object.keys(a.edges), ...Object.keys(b.edges)])) {
    if (!a.edges[id]) out.push(`edge ${id}: missing in A`)
    else if (!b.edges[id]) out.push(`edge ${id}: missing in B`)
    else walk(a.edges[id], b.edges[id], 'edge ' + id)
  }
  return out.slice(0, limit)
}
export function countDiffs(a: NGraph, b: NGraph): number {
  return diffGraphs(a, b, 1_000_000).length
}
