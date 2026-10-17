import path from 'node:path'
import { pathToFileURL } from 'node:url'
import loroPkg from 'loro-crdt/nodejs'
import { installGlobals, Sim } from './core'
import { Link, defaultLink, type LinkCfg, type LinkMode } from './net'
import { Rng } from './rng'
import { DifyServer } from './server'
import { Tab, type Real } from './tab'
import { Ledger } from './ledger'
import * as deltaMod from './delta'
import { FAST_NODELTA, FAST_NOLAZY, FAST_OFF, FAST_ON, patchLoroMutators, wrapDoc, type FastOpts } from './fastpath'

export type WorldOpts = {
  seed: number
  keepServerLog?: boolean
  db?: { baseMs: number; perNodeMs: number } // draft POST processing cost
  link?: Partial<LinkCfg>
  fast?: FastOpts
  rafDist?: number[] // calibrated main-thread latency distribution (ms) replacing the ideal 60 Hz frame lattice
  panelLagMs?: number
}

export class World {
  sim!: Sim
  server!: DifyServer
  real!: Real
  tabs: Tab[] = []
  ledger = new Ledger()
  appId = 'app-1'
  rng!: Rng
  dbBusyUntil = 0
  db = { baseMs: 25, perNodeMs: 0.08 }
  consoleSink: (lvl: string, args: unknown[], tab: Tab | undefined) => void = () => {}
  httpStats = { gets: 0, posts: 0, post409: 0, keepaliveDropped64k: 0, keepalive: 0, bytesUp: 0 }
  origConsole!: { warn: (...a: any[]) => void; error: (...a: any[]) => void; log: (...a: any[]) => void }
  opts!: WorldOpts
  traceLog: { t: number; tab: string; kind: string; info: string }[] = []
  watch: { node: string; key: string; read: (n: any) => any }[] = []
  tr(tab: string, kind: string, info = '') {
    if (this.opts.keepServerLog) this.traceLog.push({ t: this.sim.now, tab, kind, info })
  }
  watchValues(tab: any): string {
    return this.watch.map((w) => `${w.node}.${w.key}=${JSON.stringify(w.read(tab.rf.nodes.find((n: any) => n.id === w.node)))}`).join(' ')
  }
  fast: FastOpts = FAST_ON

  static async create(opts: WorldOpts): Promise<World> {
    const w = new World()
    w.opts = opts
    const envMode = process.env.SIM_FAST
    ;(globalThis as any).__SIMDELTA = deltaMod
    ;(globalThis as any).__LORO_WASM = (loroPkg as any).__wasm
    w.fast = opts.fast ?? (envMode === 'off' ? FAST_OFF : envMode === 'nolazy' ? FAST_NOLAZY : envMode === 'nodelta' ? FAST_NODELTA : envMode === 'paranoid' ? { ...FAST_ON, paranoid: true } : FAST_ON)
    patchLoroMutators(loroPkg, () => (globalThis as any).__SIMENV?.cur()?.fastCache)
    w.sim = new Sim(opts.seed)
    w.rng = new Rng(opts.seed, 'world')
    if (opts.db) w.db = opts.db
    const g = globalThis as any
    g.__SIMENV = { cur: () => w.sim.cur() }
    const { origConsole } = installGlobals(w.sim, {
      raf: (cb) => {
        const t = w.sim.cur() as Tab
        return t.raf(cb as any)
      },
      caf: (id) => (w.sim.cur() as Tab).caf(id),
      document: () => (w.sim.cur() as Tab).document,
      console: (lvl, args) => {
        const t = w.sim.cur() as Tab | undefined
        if (t) {
          if (lvl === 'error') t.stats.consoleErrors++
          else t.stats.consoleWarns++
          if (t.consoleLog.length < 50) t.consoleLog.push({ t: w.sim.now, lvl, msg: args.map((a) => String((a as any)?.message ?? a)).join(' ').slice(0, 200) })
        }
        w.consoleSink(lvl, args, t)
      },
    })
    w.origConsole = origConsole
    const modUrl = pathToFileURL(path.join(path.dirname(new URL(import.meta.url).pathname), '../../dist/real.mjs')).href
    w.real = (await import(modUrl)) as Real
    w.server = new DifyServer(w.sim, new Rng(opts.seed, 'server'))
    w.server.keepLog = !!opts.keepServerLog
    return w
  }

  seedDraft(graph: any) {
    this.server.db.seed(graph)
  }

  newTab(name: string, userId = name, linkCfg: Partial<LinkCfg> = {}): Tab {
    const cfg = { ...defaultLink(), ...this.opts.link, ...linkCfg }
    const link = new Link(this.sim, this.rng.fork('link:' + name), cfg)
    const tab = new Tab(this, name, { id: userId, name }, link)
    if (this.opts.rafDist) tab.rafLatencyDist = this.opts.rafDist
    if (this.opts.panelLagMs) tab.panelLagMs = this.opts.panelLagMs
    this.tabs.push(tab)
    return tab
  }

  // ---------------------------------------------------------------------------------------------- CRDT runtime injection
  crdtRuntimeFor(tab: Tab) {
    const R = this.real as any
    const rng = new Rng(this.opts.seed, 'peer:' + tab.name)
    const RealDoc = (loroPkg as any).LoroDoc
    const fast = this.fast
    function LoroDoc(this: any) {
      const d = new RealDoc()
      d.setPeerId(BigInt('0x' + rng.hex(15))) // fresh random 60-bit peer id per LoroDoc, like a browser
      tab.fastCache = wrapDoc(d, fast).cache
      if (fast.delta) deltaMod.enableDelta(d)
      return d
    }
    return {
      CRDTProvider: R.CRDTProvider,
      LoroDoc: LoroDoc as any,
      LoroList: (loroPkg as any).LoroList,
      LoroMap: (loroPkg as any).LoroMap,
      UndoManager: process.env.SIM_NO_UNDO ? class { canUndo() { return false } canRedo() { return false } clear() {} } : (loroPkg as any).UndoManager,
    }
  }

  // ---------------------------------------------------------------------------------------------- HTTP (console API)
  httpFor(tab: Tab) {
    const w = this
    const sim = this.sim
    const lat = (dir: 'up' | 'down') => {
      const l = tab.link
      const base = dir === 'up' ? l.cfg.upMs : l.cfg.downMs
      return Math.max(0.3, base + (l.cfg.jitterMs ? w.rng.range(-l.cfg.jitterMs, l.cfg.jitterMs) : 0))
    }
    const resp = (status: number, body: any) => {
      if (status >= 200 && status < 300) return Promise.resolve(body)
      return Promise.reject({ status, bodyUsed: false, ok: false, json: async () => body })
    }
    const request = (kind: 'GET' | 'POST', bodyStr: string | null, by: Tab, ctxAlive: boolean): Promise<any> =>
      new Promise((resolve, reject) => {
        if (tab.link.httpOffline) {
          sim.after(5, () => reject(new TypeError('Failed to fetch')), tab)
          return
        }
        const size = bodyStr ? Buffer.byteLength(bodyStr) : 200
        w.httpStats.bytesUp += size
        if (kind === 'POST') w.httpStats.posts++
        else w.httpStats.gets++
        const up = lat('up') + (tab.link.cfg.bwBps ? (size * 8000) / tab.link.cfg.bwBps : 0)
        sim.after(up, () => {
          // server: DraftWorkflowApi (row-locked draft: requests are processed one at a time)
          const body = bodyStr ? JSON.parse(bodyStr) : null
          const nodes = body?.graph?.nodes?.length ?? w.server.db.graph?.nodes?.length ?? 0
          const start = Math.max(sim.now, w.dbBusyUntil)
          const dur = w.db.baseMs + w.db.perNodeMs * nodes
          w.dbBusyUntil = start + dur
          sim.at(start + dur, () => {
            const r = kind === 'GET' ? w.server.db.get() : w.server.db.post(body, by.name)
            if (kind === 'POST' && r.status === 200) w.ledger.onSave(w.server.db.graph, sim.now)
            if (r.status === 409) w.httpStats.post409++
            by.saveLog.push({ t: sim.now, kind: kind + (ctxAlive ? '' : '-ka'), ok: r.status < 300, status: r.status, hash: r.body?.hash })
            const down = lat('down')
            sim.after(down, () => (ctxAlive ? resp(r.status, r.body).then(resolve, reject) : void 0), ctxAlive ? tab : null)
          }, null)
        }, null)
      })
    return {
      get: (url: string) => request('GET', null, tab, true),
      post: (url: string, params: any) => request('POST', JSON.stringify(params), tab, true),
      postKeepalive: (url: string, bodyStr: string) => {
        w.httpStats.keepalive++
        // Fetch spec: keepalive request bodies are capped at 64 KiB; larger ones reject (Dify swallows: .catch(() => {}))
        if (Buffer.byteLength(bodyStr) > 65536) {
          w.httpStats.keepaliveDropped64k++
          tab.saveLog.push({ t: sim.now, kind: 'POST-ka', ok: false, status: -1 })
          return
        }
        void request('POST', bodyStr, tab, false).catch(() => {})
      },
    }
  }

  // ---------------------------------------------------------------------------------------------- faults
  /** 'down' = connection refused + close existing (harness NetState.drop('refuse')); 'blackhole' = silent drop (drop('blackhole')). */
  cutLink(tab: Tab, mode: LinkMode, opts: { httpOffline?: boolean } = {}) {
    const sim = this.sim
    const link = tab.link
    link.setMode(mode)
    if (opts.httpOffline) link.httpOffline = true
    const conn = tab.socket?.conn
    if (!conn) return
    if (mode === 'down') {
      sim.after(link.cfg.upMs, () => this.server.closeConn(conn, 'transport close', false), null)
      sim.after(0, () => tab.socket?.conn?.id === conn.id && tab.socket.onclose('transport close'), tab)
    } else if (mode === 'blackhole') {
      // engine.io heartbeat: pingInterval 25 s + pingTimeout 20 s; both sides give up in the same ping cycle
      const phi = this.rng.range(0, 25_000)
      const detect = 45_000 - phi
      sim.after(detect, () => {
        if (link.mode !== 'blackhole' || tab.dead) return
        this.server.closeConn(conn, 'ping timeout', false)
        if (tab.socket?.conn?.id === conn.id) tab.socket.onclose('ping timeout')
      }, null)
    }
  }
  healLink(tab: Tab) {
    tab.link.setMode('up')
    tab.link.httpOffline = false
  }
  /** Close/crash a tab. If its link is blackholed the FIN never arrives; the server notices via heartbeat. */
  closeTab(tab: Tab, graceful: boolean) {
    const wasConn = tab.socket?.conn
    tab.closeTab(graceful)
    if (wasConn && tab.link.mode === 'blackhole') {
      const phi = this.rng.range(0, 25_000)
      this.sim.after(45_000 - phi, () => this.server.closeConn(wasConn, 'ping timeout', false), null)
    }
  }
}
