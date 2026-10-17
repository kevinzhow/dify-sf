// Transport optimisation at the Loro boundary ("delta wire", performance only).
// The real CRDTProvider exports the sender's WHOLE history (`doc.export({mode:'update'})`, ~250-330 KB for a 500-node graph) on every local
// commit and every receiver runs `doc.import(blob)` on it. In loro-crdt 1.15.1 both calls are slow (8-30 ms) and leak wasm memory when the doc
// contains List containers (measured: +0.16..0.4 MB per call; a 100-tab storm would need > 80 GB). Importing a blob is a set-union of changes, so
//   doc.import(wholeHistoryBlob)  ==  doc.importJsonUpdates(changes the receiver lacks, up to the blob's version)
// (same document state, same version vector, same events with by='import': checked in scripts/delta-equiv.mjs and by the digests equivalence run).
// In delta mode `export({mode:'update'})` returns a 16-byte marker bound to (sender doc, version) and the receiver imports the missing changes
// from the sender's still-alive doc. Bytes on the wire are accounted with an estimate of the real blob size (size of one real export + 1.5 B/op).
export type DeltaMeta = { doc: any; vv: any; vvMap: Map<string, number>; size: number }
const MAGIC = [0x44, 0x45, 0x4c, 0x54] // 'DELT'
const registry = new Map<number, DeltaMeta>()
let seq = 1

export const isMarker = (b: any): boolean => {
  const u: Uint8Array | null = b instanceof Uint8Array ? b : b instanceof ArrayBuffer ? new Uint8Array(b) : null
  return !!u && u.byteLength === 16 && MAGIC.every((m, i) => u[i] === m)
}
const idOf = (b: any): number => {
  const u: Uint8Array = b instanceof Uint8Array ? b : new Uint8Array(b)
  return new DataView(u.buffer, u.byteOffset, 16).getUint32(4)
}
export const markerMeta = (b: any): DeltaMeta | undefined => (isMarker(b) ? registry.get(idOf(b)) : undefined)
export const markerSize = (b: any): number => markerMeta(b)?.size ?? 16

export function makeMarker(meta: DeltaMeta): Uint8Array {
  const id = seq++
  registry.set(id, meta)
  if (registry.size > 60_000) for (const k of registry.keys()) { registry.delete(k); if (registry.size < 40_000) break }
  const u = new Uint8Array(16)
  u.set(MAGIC, 0)
  new DataView(u.buffer).setUint32(4, id)
  return u
}

/** wrap one LoroDoc instance (no prototype change) */
export function enableDelta(d: any) {
  const origExport = d.export.bind(d)
  const origImport = d.import.bind(d)
  let size0 = 0
  let ops0 = 0
  d.export = (opts?: any) => {
    if (opts?.mode === 'update' && !opts.from) {
      const ops = d.opCount()
      if (!size0 || ops - ops0 > 4000) {
        size0 = origExport(opts).length // one real export now and then keeps the size estimate honest
        ops0 = ops
      }
      const vv = d.oplogVersion()
      const vvMap = new Map<string, number>()
      for (const [p, c] of vv.toJSON() as Map<string, number>) vvMap.set(String(p), c)
      return makeMarker({ doc: d, vv, vvMap, size: Math.round(size0 + 1.5 * (ops - ops0)) })
    }
    return origExport(opts)
  }
  d.import = (bytes: any) => {
    const meta = markerMeta(bytes)
    if (!meta) return origImport(bytes)
    if (meta.doc === d) return { success: new Map(), pending: null }
    const json = meta.doc.exportJsonUpdates(d.oplogVersion(), meta.vv)
    return d.importJsonUpdates(json)
  }
  return d
}
