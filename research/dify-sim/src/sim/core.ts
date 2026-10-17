// Virtual clock + deterministic event scheduler + per-client execution context (AsyncLocalStorage).
// Everything that real Dify client code would get from the browser's event loop (setTimeout, requestAnimationFrame,
// Date.now, microtask ordering) is provided here. See FIDELITY.md section "Environment".
import { AsyncLocalStorage } from 'node:async_hooks'
import { Rng } from './rng'

export const EPOCH_MS = 1_800_000_000_000 // arbitrary fixed wall-clock origin (Date.now() = EPOCH_MS + virtual ms)

type Ev = { t: number; seq: number; fn: () => void; ctx: unknown; dead: boolean; tag?: string }

class Heap {
  a: Ev[] = []
  get size() {
    return this.a.length
  }
  private less(x: Ev, y: Ev) {
    return x.t < y.t || (x.t === y.t && x.seq < y.seq)
  }
  push(e: Ev) {
    const a = this.a
    a.push(e)
    let i = a.length - 1
    while (i > 0) {
      const p = (i - 1) >> 1
      if (!this.less(a[i]!, a[p]!)) break
      ;[a[i], a[p]] = [a[p]!, a[i]!]
      i = p
    }
  }
  peek() {
    return this.a[0]
  }
  pop(): Ev | undefined {
    const a = this.a
    if (!a.length) return undefined
    const top = a[0]!
    const last = a.pop()!
    if (a.length) {
      a[0] = last
      let i = 0
      for (;;) {
        const l = 2 * i + 1
        const r = l + 1
        let m = i
        if (l < a.length && this.less(a[l]!, a[m]!)) m = l
        if (r < a.length && this.less(a[r]!, a[m]!)) m = r
        if (m === i) break
        ;[a[i], a[m]] = [a[m]!, a[i]!]
        i = m
      }
    }
    return top
  }
}

export type Handle = { cancel(): void; ev: Ev }

export class Sim {
  now = 0
  seq = 0
  heap = new Heap()
  als = new AsyncLocalStorage<any>()
  rng: Rng
  stats = { events: 0 }
  errors: { t: number; err: string }[] = []
  stopped = false
  gcEvery = process.env.SIM_GC_EVERY ? Number(process.env.SIM_GC_EVERY) : 300
  onEventError?: (e: unknown) => void
  private realSetImmediate = setImmediate

  constructor(public seed: number) {
    this.rng = new Rng(seed, 'sim')
  }

  cur<T = any>(): T | undefined {
    return this.als.getStore()
  }

  at(t: number, fn: () => void, ctx: unknown = this.als.getStore(), tag?: string): Handle {
    if (t < this.now) t = this.now
    const ev: Ev = { t, seq: this.seq++, fn, ctx, dead: false, tag }
    this.heap.push(ev)
    return { cancel: () => (ev.dead = true), ev }
  }
  after(ms: number, fn: () => void, ctx: unknown = this.als.getStore(), tag?: string): Handle {
    return this.at(this.now + Math.max(0, ms), fn, ctx, tag)
  }

  /** Run until virtual time `until` (ms) or the queue drains. Microtasks are fully drained between events,
   * exactly like a browser event loop runs the microtask checkpoint after every task. */
  async run(until = Infinity): Promise<void> {
    while (!this.stopped) {
      const e = this.heap.peek()
      if (!e || e.t > until) break
      this.heap.pop()
      if (e.dead) continue
      if (e.ctx && (e.ctx as any).dead) continue // events of a closed/crashed tab never run
      this.now = e.t
      this.stats.events++
      if (e.ctx && (e.ctx as any).lazy) (e.ctx as any).beforeEvent(e.tag)
      try {
        this.als.run(e.ctx, e.fn)
      } catch (err) {
        this.errors.push({ t: this.now, err: String((err as any)?.stack ?? err) })
        this.onEventError?.(err)
      }
      await new Promise<void>((r) => this.realSetImmediate(r))
      // wasm-bindgen container handles are freed by FinalizationRegistry only after a JS GC; V8 does not see wasm memory pressure, so force it
      if (this.gcEvery && this.stats.events % this.gcEvery === 0) (globalThis as any).gc?.()
    }
    if (until !== Infinity && this.now < until) this.now = until
  }
  stop() {
    this.stopped = true
  }
}

export let SIM: Sim

/** Install virtual-time globals. Must be called before loading the bundled Dify modules. */
export function installGlobals(sim: Sim, hooks: { raf: (cb: FrameRequestCallback) => number; caf: (id: number) => void; document: () => any; console: (lvl: string, args: unknown[]) => void }) {
  SIM = sim
  const g = globalThis as any
  let timerId = 1
  const timers = new Map<number, Handle>()
  Date.now = () => EPOCH_MS + Math.floor(sim.now)
  g.performance = Object.assign(Object.create(null), { now: () => sim.now, timeOrigin: EPOCH_MS })
  g.setTimeout = (fn: (...a: any[]) => void, ms = 0, ...args: any[]) => {
    const id = timerId++
    const h = sim.after(Math.max(1, Number(ms) || 0), () => {
      timers.delete(id)
      fn(...args)
    })
    timers.set(id, h)
    return id
  }
  g.clearTimeout = (id: number) => {
    const h = timers.get(id)
    if (h) {
      h.cancel()
      timers.delete(id)
    }
  }
  g.setInterval = (fn: (...a: any[]) => void, ms = 0, ...args: any[]) => {
    const id = timerId++
    const tick = () => {
      timers.set(id, sim.after(Math.max(1, Number(ms) || 0), tick))
      fn(...args)
    }
    timers.set(id, sim.after(Math.max(1, Number(ms) || 0), tick))
    return id
  }
  g.clearInterval = g.clearTimeout
  g.requestAnimationFrame = hooks.raf
  g.cancelAnimationFrame = hooks.caf
  g.queueMicrotask = queueMicrotask
  const rnd = new Rng(sim.seed, 'math-random')
  Math.random = () => rnd.next()
  const uuidRng = new Rng(sim.seed, 'uuid')
  Object.defineProperty(globalThis, 'crypto', {
    configurable: true,
    value: {
      randomUUID: () => {
        const h = uuidRng.hex(32)
        return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`
      },
      getRandomValues: (arr: Uint8Array) => {
        for (let i = 0; i < arr.length; i++) arr[i] = uuidRng.int(256)
        return arr
      },
    },
  })
  const doc = new Proxy({}, {
    get: (_t, k) => hooks.document()[k],
    set: (_t, k, v) => {
      hooks.document()[k] = v
      return true
    },
  })
  Object.defineProperty(g, 'document', { configurable: true, get: () => (sim.cur() ? doc : undefined) })
  Object.defineProperty(g, 'window', { configurable: true, get: () => (sim.cur() ? doc : undefined) })
  const origConsole = { warn: console.warn, error: console.error, log: console.log }
  console.warn = (...a: unknown[]) => hooks.console('warn', a)
  console.error = (...a: unknown[]) => hooks.console('error', a)
  return { origConsole }
}
