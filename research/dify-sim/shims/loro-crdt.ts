// The real loro-crdt npm package (1.15.1, nodejs build of the same Rust core as the browser build).
// decodeImportBlobMeta is a pure function of the blob bytes; the relay delivers identical bytes to every room member, so the result is
// memoized by content hash (performance only; identical return value).
import pkg from 'loro-crdt/nodejs'
import { createHash } from 'node:crypto'
const p = pkg as any
const cache = new Map<string, any>()
const byBuf = new WeakMap<ArrayBufferLike, any>()
const delta = (): any => (globalThis as any).__SIMDELTA
export const decodeImportBlobMeta = (bytes: Uint8Array, check: boolean) => {
  const dm = delta()?.markerMeta(bytes)
  if (dm) {
    // delta wire marker (src/sim/delta.ts): same fields the real decoder returns for a from-scratch `update` blob
    return { mode: 'update', endVV: dm.vvMap, partialEndVersionVector: dm.vv, __len: 16 }
  }
  // the simulated relay hands every room member the same immutable ArrayBuffer: identity hit first
  if (bytes.byteOffset === 0 && !check) {
    const h = byBuf.get(bytes.buffer)
    if (h && h.__len === bytes.byteLength) return h
  }
  const key = createHash('sha1').update(bytes).digest('latin1') + (check ? 'c' : 'n')
  let v = cache.get(key)
  if (!v) {
    v = p.decodeImportBlobMeta(bytes, check)
    if (cache.size > 256) cache.delete(cache.keys().next().value!)
    cache.set(key, v)
  }
  if (bytes.byteOffset === 0 && !check) {
    try { v.__len = bytes.byteLength; byBuf.set(bytes.buffer, v) } catch { /* frozen meta */ }
  }
  return v
}
export const { LoroDoc, LoroList, LoroMap, UndoManager } = p
export default pkg
