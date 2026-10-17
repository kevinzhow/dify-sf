// Network model: per-tab link with independent up/down FIFO pipes (TCP-like ordering), latency + jitter, loss modeled as TCP
// retransmission delay (a lost segment delays itself and everything behind it), bandwidth, and fault modes.
import type { Sim } from './core'
import { Rng } from './rng'

export type LinkMode = 'up' | 'down' | 'blackhole'
export type LinkCfg = {
  upMs: number
  downMs: number
  jitterMs: number // uniform +/- on each packet (ordering preserved by FIFO)
  loss: number // per-packet loss probability; a lost packet is retransmitted after rtoMs (doubling)
  rtoMs: number
  bwBps: number // 0 = infinite
}
export const defaultLink = (): LinkCfg => ({ upMs: 15, downMs: 15, jitterMs: 3, loss: 0, rtoMs: 200, bwBps: 0 })

export class Pipe {
  last = 0
  bytes = 0
  pkts = 0
  constructor(private sim: Sim, private rng: Rng, private dir: 'up' | 'down', private link: Link) {}
  /** returns the scheduled delivery time, or -1 if dropped. */
  send(bytes: number, deliver: () => void, ctx: unknown, tag?: string): number {
    const l = this.link
    if (l.mode === 'blackhole') return -1
    const cfg = l.cfg
    const base = this.dir === 'up' ? cfg.upMs : cfg.downMs
    let lat = base + (cfg.jitterMs ? this.rng.range(-cfg.jitterMs, cfg.jitterMs) : 0)
    if (lat < 0.2) lat = 0.2
    let rto = cfg.rtoMs
    while (cfg.loss > 0 && this.rng.chance(cfg.loss)) {
      lat += rto
      rto *= 2
    }
    const ser = cfg.bwBps > 0 ? (bytes * 8 * 1000) / cfg.bwBps : 0
    const t = Math.max(this.sim.now + lat + ser, this.last + 0.001)
    this.last = t
    this.bytes += bytes
    this.pkts++
    const sentAt = this.sim.now
    this.sim.at(
      t,
      () => {
        // a blackhole that started after this packet was sent but before it arrives still eats it only if sent after the cut
        if (l.mode === 'blackhole' && sentAt >= l.cutAt) return
        deliver()
      },
      ctx,
      tag,
    )
    return t
  }
}

export class Link {
  mode: LinkMode = 'up'
  cutAt = Infinity
  up: Pipe
  down: Pipe
  http: { upMs: number; downMs: number; jitterMs: number }
  httpOffline = false
  constructor(public sim: Sim, rng: Rng, public cfg: LinkCfg = defaultLink()) {
    this.up = new Pipe(sim, rng.fork('up'), 'up', this)
    this.down = new Pipe(sim, rng.fork('down'), 'down', this)
    this.http = { upMs: cfg.upMs, downMs: cfg.downMs, jitterMs: cfg.jitterMs }
  }
  setMode(m: LinkMode) {
    if (m === 'blackhole' && this.mode !== 'blackhole') this.cutAt = this.sim.now
    if (m !== 'blackhole') this.cutAt = Infinity
    this.mode = m
  }
}

/** rough wire size of a socket.io packet (JSON text + binary attachments) */
import { isMarker, markerSize } from './delta'
export function wireSize(v: unknown): number {
  let n = 0
  const walk = (x: any): void => {
    if (x == null) {
      n += 4
    } else if (x instanceof Uint8Array) {
      n += (isMarker(x) ? markerSize(x) : x.byteLength) + 16
    } else if (x instanceof ArrayBuffer) {
      n += (isMarker(x) ? markerSize(x) : x.byteLength) + 16
    } else if (typeof x === 'string') {
      n += x.length + 2
    } else if (typeof x === 'number' || typeof x === 'boolean') {
      n += 8
    } else if (Array.isArray(x)) {
      n += 2
      for (const y of x) walk(y)
    } else if (typeof x === 'function') {
      n += 0
    } else if (typeof x === 'object') {
      n += 2
      for (const k of Object.keys(x)) {
        n += k.length + 3
        walk(x[k])
      }
    }
  }
  walk(v)
  return n
}
/** socket.io-client delivers binary as ArrayBuffer in browsers; copy so no JS object is shared across the wire. */
export function wireCopy<T>(v: T, binaryAs: 'arraybuffer' | 'uint8array' = 'arraybuffer', shareBinary = false): T {
  const walk = (x: any): any => {
    if (x == null || typeof x !== 'object') return x
    if (x instanceof Uint8Array) {
      const c = new Uint8Array(x.byteLength)
      c.set(x)
      return binaryAs === 'arraybuffer' ? c.buffer : c
    }
    if (x instanceof ArrayBuffer) {
      if (shareBinary) return x // immutable once on the wire; the relay fans the same bytes out to every room member
      const c = x.slice(0)
      return binaryAs === 'arraybuffer' ? c : new Uint8Array(c)
    }
    if (Array.isArray(x)) return x.map(walk)
    const o: any = {}
    for (const k of Object.keys(x)) o[k] = walk(x[k])
    return o
  }
  return walk(v)
}
