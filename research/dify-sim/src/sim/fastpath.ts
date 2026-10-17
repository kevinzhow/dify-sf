// Performance-only environment layer. It never changes what the Dify code computes; it removes redundant host CPU work:
//  1. diagnostics stubs (startImportLog / finalizeImportLog / recordGraphSyncDiagnostic / captureSetNodesAnomaly): they only append to
//     bounded log arrays (collaboration-manager.ts:1583-1743, 1614-1660) that nothing in the data path reads.
//  2. exportNode memo (collaboration-manager.ts:336): result of container.toJSON() cached per node id, invalidated by Loro events
//     (import: by event path) and by every local write (all nodes dirty until the next commit event).
//  3. edgesMap.values() memo, invalidated the same way.
// `paranoid` re-computes every cache hit and throws on mismatch (used by the equivalence tests).
export type FastOpts = { stubDiagnostics: boolean; memo: boolean; lazy?: boolean; delta?: boolean; paranoid?: boolean }
export const FAST_ON: FastOpts = { stubDiagnostics: true, memo: true, lazy: true, delta: true }
export const FAST_NOLAZY: FastOpts = { stubDiagnostics: true, memo: true, delta: false }
export const FAST_NODELTA: FastOpts = { stubDiagnostics: true, memo: true, lazy: true }
export const FAST_OFF: FastOpts = { stubDiagnostics: false, memo: false }

const stableEq = (a: any, b: any) => JSON.stringify(a) === JSON.stringify(b)

/** wraps LoroDoc so that cache invalidation sees every mutation */
export function wrapDoc(doc: any, opts: FastOpts) {
  if (!opts.memo) return { doc, cache: null as any }
  const nodeCache = new Map<string, any>()
  const edgeCache: { v: any[] | null } = { v: null }
  const dirtyAll = () => {
    nodeCache.clear()
    edgeCache.v = null
  }
  doc.subscribe((ev: any) => {
    if (ev.by !== 'import') {
      dirtyAll()
      return
    }
    for (const e of ev.events) {
      const p = e.path as (string | number)[]
      if (p[0] === 'nodes') {
        if (p.length >= 2) nodeCache.delete(String(p[1]))
        else if (e.diff?.type === 'map') for (const k of Object.keys(e.diff.updated ?? {})) nodeCache.delete(k)
        else nodeCache.clear()
      } else if (p[0] === 'edges') edgeCache.v = null
      else if (p.length === 0) dirtyAll()
    }
  })
  return { doc, cache: { nodeCache, edgeCache, dirtyAll } }
}

const MUT = new Set(['set', 'delete', 'setContainer', 'clear', 'insert', 'insertContainer', 'push', 'pushContainer', 'update', 'applyDelta'])

/** instrument one manager instance */
export function instrumentManager(m: any, cacheRef: { cache: any } | null, opts: FastOpts) {
  if (opts.stubDiagnostics) {
    m.startImportLog = () => {}
    m.finalizeImportLog = () => {}
    m.recordGraphSyncDiagnostic = () => {}
    m.captureSetNodesAnomaly = () => {}
  }
  if (!opts.memo || !cacheRef) return
  const orig = m.exportNode.bind(m)
  m.exportNode = (nodeId: string) => {
    const c = cacheRef.cache
    if (!c) return orig(nodeId)
    const hit = c.nodeCache.get(nodeId)
    if (hit) {
      if (opts.paranoid) {
        const fresh = orig(nodeId)
        if (!stableEq(fresh, hit)) throw new Error('memo exportNode mismatch for ' + nodeId)
      }
      return { ...hit }
    }
    const fresh = orig(nodeId)
    c.nodeCache.set(nodeId, fresh)
    return { ...fresh }
  }
  // getEdges: Array.from(this.edgesMap.values())
  const origGetEdges = m.getEdges.bind(m)
  m.getEdges = () => {
    const c = cacheRef.cache
    if (!c || !m.edgesMap) return origGetEdges()
    if (c.edgeCache.v) {
      if (opts.paranoid && !stableEq(origGetEdges(), c.edgeCache.v)) throw new Error('memo getEdges mismatch')
      return c.edgeCache.v.slice()
    }
    const fresh = origGetEdges()
    c.edgeCache.v = fresh
    return fresh.slice()
  }
}

/** make local writes invalidate: patch the containers' prototype methods once per process (they are shared wasm classes) */
export function patchLoroMutators(loro: any, getCache: () => any) {
  for (const cls of [loro.LoroMap, loro.LoroList]) {
    for (const k of Object.getOwnPropertyNames(cls.prototype)) {
      if (!MUT.has(k) || (cls.prototype[k] as any).__patched) continue
      const orig = cls.prototype[k]
      const w = function (this: any, ...a: any[]) {
        getCache()?.dirtyAll()
        return orig.apply(this, a)
      }
      ;(w as any).__patched = true
      cls.prototype[k] = w
    }
  }
  const D = loro.LoroDoc.prototype
  for (const k of ['import', 'importBatch', 'checkout', 'applyDiff', 'setPeerId']) {
    if (!D[k] || D[k].__patched) continue
    if (k === 'import' || k === 'importBatch') continue // import invalidation is driven by event paths
    const orig = D[k]
    const w = function (this: any, ...a: any[]) {
      getCache()?.dirtyAll()
      return orig.apply(this, a)
    }
    ;(w as any).__patched = true
    D[k] = w
  }
}
