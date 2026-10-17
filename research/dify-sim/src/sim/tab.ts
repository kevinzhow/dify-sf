// One simulated browser tab running the Dify workflow editor in collaboration mode.
// REAL Dify code (dist/real.mjs): CollaborationManager, CRDTProvider, WebSocketClient, use-collaborative-workflow, use-node-data-update,
// use-node-crud, workflow-app/use-nodes-sync-draft, use-workflow-refresh-draft, use-workflow-update, workflow-draft-slice (debounce 5 s), use-serial-async-callback.
// Re-implemented here ("app shell", see FIDELITY.md): the React component effects of workflow/index.tsx and workflow-app/components/workflow-main.tsx.
import type { World } from './world'
import type { Link } from './net'
import { FakeSocket } from './fakesocket'
import type { ServerTab } from './server'
import { initialEdgesImpl, initialNodesImpl } from './workflow-init'
import { instrumentManager } from './fastpath'

export type Real = typeof import('../../dist/real.mjs')

export class Tab implements ServerTab {
  dead = false
  connId = 0
  stats = { bytesUp: 0, uncaught: 0, consoleErrors: 0, consoleWarns: 0, rafCallbacks: 0 }
  consoleLog: { t: number; lvl: string; msg: string }[] = []
  uncaught: { t: number; where: string; err: string }[] = []
  // --- browser state ---
  visibility: 'visible' | 'hidden' = 'visible'
  private docListeners = new Map<string, Set<(e?: any) => void>>()
  private rafQ: { id: number; cb: (t: number) => void }[] = []
  private rafSeq = 1
  private frameH: { cancel(): void } | null = null
  private framePhase = 0
  rafDelayMs = 0 // stress knob (slow main thread), same meaning as harness set_raf_delay
  // --- ReactFlow / stores ---
  private _rfNodes: any[] = []
  private _rfEdges: any[] = []
  onRfChange: ((t: Tab) => void) | null = null
  /** React render lag of the node panel: the panel's `inputs` (what setInputs() writes back as a whole) are the node data as of `panelLagMs` ago
   *  (store update -> React commit; measured from real Chromium under load in calibration, 0 = ideal). */
  panelLagMs = 0
  private rfHist: { t: number; nodes: any[] }[] = []
  recordRf(v: any[]) {
    const now = this.world.sim.now
    this.rfHist.push({ t: now, nodes: v })
    const cut = now - this.panelLagMs - 2000
    while (this.rfHist.length > 2 && this.rfHist[1]!.t < cut) this.rfHist.shift()
  }
  /** the panel's view of node `id` */
  panelNode(id: string): any {
    if (this.panelLagMs <= 0 || !this.rfHist.length) return this._rfNodes.find((n: any) => n.id === id)
    const at = this.world.sim.now - this.panelLagMs
    let pick = this.rfHist[0]!
    for (const h of this.rfHist) { if (h.t <= at) pick = h; else break }
    return pick.nodes.find((n: any) => n.id === id) ?? this._rfNodes.find((n: any) => n.id === id)
  }
  rf = (() => {
    const t = this
    return {
      get nodes() { return t._rfNodes },
      set nodes(v: any[]) { t._rfNodes = v; if (t.panelLagMs > 0) t.recordRf(v); t.onRfChange?.(t) },
      get edges() { return t._rfEdges },
      set edges(v: any[]) { t._rfEdges = v; t.onRfChange?.(t) },
      viewport: { x: 0, y: 0, zoom: 1 },
    }
  })()
  reactNodes: any[] = [] // React state of <Workflow>: useNodesState/useEdgesState
  reactEdges: any[] = []
  wfState: any
  hooksState: any = {}
  eventEmitterSubs = new Set<(v: any) => void>()
  // --- Dify instances ---
  manager: any
  fastCache: any = null
  wsClient: any
  socket: FakeSocket | null = null
  hooks: any = {}
  appId = ''
  connectionId = ''
  loaded = false
  // --- bookkeeping for metrics ---
  saveLog: { t: number; kind: string; ok: boolean; status?: number; hash?: string }[] = []
  graphImportCount = 0
  editsAttempted = 0
  editsBlocked = 0
  openedAt = 0

  constructor(public world: World, public name: string, public user: { id: string; name: string }, public link: Link) {
    this.framePhase = world.sim.rng.range(0, 16.667)
  }

  // ===================================================================== env bridge used by the shims
  get rfStoreApi() {
    const t = this
    return {
      getState: () => ({
        getNodes: () => t.rf.nodes,
        setNodes: (n: any[]) => {
          t.rf.nodes = n
        },
        getEdges: () => t.rf.edges,
        edges: t.rf.edges,
        setEdges: (e: any[]) => {
          t.rf.edges = e
        },
        transform: [t.rf.viewport.x, t.rf.viewport.y, t.rf.viewport.zoom],
      }),
    }
  }
  get reactFlowInstance() {
    const t = this
    return { setViewport: (v: any) => (t.rf.viewport = v), getNodes: () => t.rf.nodes, setNodes: (n: any[]) => (t.rf.nodes = n), getEdges: () => t.rf.edges, setEdges: (e: any[]) => (t.rf.edges = e) }
  }
  get workflowStore() {
    return { getState: () => this.wfState, setState: (p: any) => Object.assign(this.wfState, p) }
  }
  get featuresStore() {
    return {
      getState: () => ({
        features: { opening: { enabled: false }, suggested: { enabled: false }, text2speech: { enabled: false }, speech2text: { enabled: false }, citation: { enabled: false }, moderation: { enabled: false }, file: { enabled: false } },
      }),
    }
  }
  get eventEmitter() {
    return { emit: (v: any) => this.eventEmitterSubs.forEach((f) => f(v)) }
  }
  initialNodes = (n: any[], e: any[]) => initialNodesImpl(n, e)
  initialEdges = (e: any[], n: any[]) => initialEdgesImpl(e, n)
  createSocket = (_url: string, _opts: any) => {
    this.socket = new FakeSocket(this)
    return this.socket
  }
  get http() {
    return this.world.httpFor(this)
  }
  onUncaught(e: unknown, where: string) {
    this.stats.uncaught++
    if (this.uncaught.length < 20) this.uncaught.push({ t: this.world.sim.now, where, err: String((e as any)?.stack ?? e).slice(0, 600) })
  }

  // ===================================================================== browser primitives
  get document() {
    const t = this
    return {
      get visibilityState() {
        return t.visibility
      },
      get hidden() {
        return t.visibility === 'hidden'
      },
      addEventListener: (type: string, fn: (e?: any) => void) => {
        if (!t.docListeners.has(type)) t.docListeners.set(type, new Set())
        t.docListeners.get(type)!.add(fn)
      },
      removeEventListener: (type: string, fn: (e?: any) => void) => t.docListeners.get(type)?.delete(fn),
    }
  }
  private fireDoc(type: string) {
    this.world.sim.als.run(this, () => {
      for (const f of [...(this.docListeners.get(type) ?? [])]) {
        try {
          f({ type })
        } catch (e) {
          this.onUncaught(e, 'document.' + type)
        }
      }
    })
  }
  // ---- requestAnimationFrame: frames at 60 Hz (per-tab phase); paused while hidden (Chrome behaviour, repro HIDDEN_INIT) ----
  private frameAt = Infinity // time of the next frame that will run queued callbacks (Infinity: none due)
  lazy = false // lazy ingest mode (see ingest section)
  noLazy = false
  replaying = false
  raf(cb: (t: number) => void): number {
    if (process.env.SIM_DROP_RAF) return 0
    const id = this.rafSeq++
    if (this.rafDelayMs > 0 && this.visibility !== 'hidden') {
      // Same as the harness's set_raf_delay: every callback gets its own setTimeout(rafDelayMs) and only then a
      // real rAF, so callbacks registered during the delay are not batched into one earlier frame.
      this.rafDelayed.add(id)
      this.world.sim.after(this.rafDelayMs, () => {
        if (!this.rafDelayed.delete(id) || this.dead) return
        this.rafQ.push({ id, cb })
        this.ensureFrame()
      }, this)
      return id
    }
    this.rafQ.push({ id, cb })
    this.ensureFrame()
    return id
  }
  private rafDelayed = new Set<number>()
  caf(id: number) {
    this.rafDelayed.delete(id)
    this.rafQ = this.rafQ.filter((x) => x.id !== id)
  }
  /** calibration: empirical (sorted) distribution of "message arrival -> rAF callback" latency measured in real Chromium (calib/probe_stats.py).
   *  When set it replaces the ideal 60 Hz lattice; the draw is a pure function of (tab seed, registration time) so that exact and lazy modes agree. */
  rafLatencyDist: number[] | null = null
  private latSeed = 0
  private computeFrameAt(): number {
    const sim = this.world.sim
    if (this.rafLatencyDist && this.rafLatencyDist.length) {
      if (!this.latSeed) { let h = 2166136261; for (const ch of this.name + ':' + this.world.opts.seed) { h ^= ch.charCodeAt(0); h = Math.imul(h, 16777619) } this.latSeed = h >>> 0 || 1 }
      let x = (this.latSeed ^ Math.floor(sim.now * 10)) >>> 0
      x = Math.imul(x ^ (x >>> 16), 0x45d9f3b) >>> 0; x = Math.imul(x ^ (x >>> 16), 0x45d9f3b) >>> 0; x = (x ^ (x >>> 16)) >>> 0
      const d = this.rafLatencyDist
      return sim.now + Math.max(0.5, d[Math.floor((x / 4294967296) * d.length)]!)
    }
    const P = 1000 / 60
    const k = Math.ceil((sim.now - this.framePhase) / P + 1e-9)
    let t = this.framePhase + k * P
    if (t <= sim.now) t += P
    return t
  }
  private ensureFrame() {
    if (this.dead || this.visibility === 'hidden' || !this.rafQ.length || this.frameAt !== Infinity) return
    this.frameAt = this.computeFrameAt()
    if (!this.lazy) this.frameH = this.world.sim.at(this.frameAt, () => this.runFrame(), this)
  }
  private runFrame() {
    this.frameH = null
    this.frameAt = Infinity
    const q = this.rafQ
    this.rafQ = []
    const before = this.world.opts.keepServerLog ? this.world.watchValues(this) : ''
    for (const { cb } of q) {
      this.stats.rafCallbacks++
      try {
        cb(this.world.sim.now)
      } catch (e) {
        this.onUncaught(e, 'rAF')
      }
    }
    if (this.world.opts.keepServerLog) { const after = this.world.watchValues(this); this.world.tr(this.name, 'rAF frame', `${q.length} cb; canvas: ${after}${after !== before ? '  (changed)' : ''}`) }
    this.ensureFrame()
  }

  // ---- lazy ingest (performance mode, see FIDELITY.md "lazy ingest") ----
  // Plain CRDT `update` deliveries and the rAF callbacks they trigger are deferred until the next event that could observe this tab
  // (any non-delivery event: local edit, timer, socket status, visibility, save...). At that point the tab's private timeline
  // (imports, frames) is replayed in virtual-time order up to "now", with redundant imports pruned: an `update` blob contains the sender's
  // WHOLE history, so a blob whose version vector is covered by a later kept blob adds no operations.
  pendingImports: { t: number; blob: ArrayBuffer; vv: Map<string, number> }[] = []
  ingestStats = { delivered: 0, applied: 0, pruned: 0, flushes: 0 }
  beforeEvent(tag: string | undefined) {
    if (!this.lazy) return
    if (tag === 'down:graph_update') return
    this.flush(this.world.sim.now)
  }
  /** called from onServerPacket for graph_update when lazy */
  private tryDefer(args: any[]): boolean {
    const blob = args[0]
    const bytes = new Uint8Array(blob)
    let meta: any
    try {
      meta = this.world.real.decodeImportBlobMeta(bytes, false)
      meta.endVV ??= new Map(Object.entries(meta.partialEndVersionVector.toJSON() instanceof Map ? Object.fromEntries(meta.partialEndVersionVector.toJSON()) : meta.partialEndVersionVector.toJSON()))
    } catch {
      return false
    }
    if (meta.mode !== 'update') return false
    // only defer while the CRDT is trusted/steady; otherwise (initial sync, reload) use the exact path
    const m = this.manager
    if (!m || !m.crdtTrusted || m.awaitingSnapshotImport || m.graphReloadRequired) return false
    this.ingestStats.delivered++
    this.pendingImports.push({ t: this.world.sim.now, blob, vv: meta.endVV })
    return true
  }
  flush(upTo: number) {
    if (!this.lazy || this.dead || this.replaying) return
    const sim = this.world.sim
    if (!this.pendingImports.length && this.frameAt > upTo) return
    this.ingestStats.flushes++
    // Exact pruning rule. An `update` blob holds the sender's whole history, so import I_i is redundant iff a LATER blob I_j covers its version
    // vector AND I_j reaches this tab before the frame that would have run the rAF callbacks registered by I_i (so no frame can observe a CRDT state
    // that lacks I_i's operations). Such an import (and the callbacks it would have registered, which I_j registers again in the same frame) are skipped.
    const imps = this.pendingImports
    this.pendingImports = []
    const covers = (a: Map<string, number>, b: Map<string, number>) => {
      for (const [p, c] of b) if (c > (a.get(p) ?? 0)) return false
      return true
    }
    const saved = sim.now
    let ii = 0
    this.replaying = true // replay executes the real handlers (frames must NOT be scheduled as sim events while we drive them here)
    try {
      sim.als.run(this, () => {
        for (;;) {
          const tImp = ii < imps.length ? imps[ii]!.t : Infinity
          const tFr = this.frameAt
          const t = Math.min(tImp, tFr)
          if (t > upTo || t === Infinity) break
          sim.now = Math.max(t, 0)
          if (tImp <= tFr) {
            const it = imps[ii]!
            // frame that will run I_i's callbacks: the already pending one, else the next lattice frame (never, while hidden)
            const F = this.frameAt !== Infinity ? this.frameAt : this.visibility === 'hidden' ? Infinity : this.computeFrameAt()
            let redundant = false
            for (let j = ii + 1; j < imps.length && j <= ii + 8; j++) {
              if (imps[j]!.t > F) break
              if (covers(imps[j]!.vv, it.vv)) { redundant = true; break }
            }
            ii++
            if (redundant) { this.ingestStats.pruned++; continue }
            this.ingestStats.applied++
            this.socket?.deliver('graph_update', [it.blob])
          } else {
            this.runFrame()
          }
        }
      })
    } finally {
      sim.now = saved
      this.replaying = false
    }
  }

  setVisibility(v: 'visible' | 'hidden') {
    if (this.visibility === v || this.dead) return
    this.flush(this.world.sim.now)
    this.visibility = v
    this.fireDoc('visibilitychange')
    if (v === 'visible') this.ensureFrame()
    else this.frameAt = Infinity
  }

  // ===================================================================== ServerTab (transport callbacks)
  onServerPacket(connId: number, ev: string, args: any[], ackId?: number) {
    if (this.dead || !this.socket || this.socket.conn?.id !== connId) return
    if (this.lazy && !this.replaying && ev === 'graph_update' && this.tryDefer(args)) return
    if (this.lazy) this.flush(this.world.sim.now)
    this.socket.deliver(ev, args, ackId)
  }
  onServerAck(_c: number, _a: number, _args: any[]) {}
  onServerClose(connId: number, reason: string) {
    if (this.dead || !this.socket || this.socket.conn?.id !== connId) return
    this.socket.onclose(reason)
  }

  // ===================================================================== lifecycle
  /** Page load: GET draft -> render ReactFlow -> mount effects (collaboration connect, listeners). */
  async open(appId: string): Promise<void> {
    this.appId = appId
    this.openedAt = this.world.sim.now
    await this.world.sim.als.run(this, () => this.openInner(appId))
  }
  private async openInner(appId: string) {
    const R = this.world.real
    R.setAutoFreeze(false) // workflow/index.tsx:369
    // --- useWorkflowInit: fetch draft ---
    const res = await this.http.get(`/apps/${appId}/workflows/draft`)
    if (this.dead) return
    // --- workflow store: real draft slice (debounced 5 s autosave) ---
    const slice = R.createWorkflowDraftSlice((fn: any) => Object.assign(this.wfState, typeof fn === 'function' ? fn(this.wfState) : fn), () => this.wfState, {} as any)
    this.wfState = {
      ...slice,
      appId,
      conversationVariables: [],
      isWorkflowDataLoaded: true,
      syncWorkflowDraftHash: res.hash,
      isListening: false,
      workflowRunningData: undefined,
      draftUpdatedAt: res.updated_at,
      setDraftUpdatedAt: (v: number) => (this.wfState.draftUpdatedAt = v),
      setEnvironmentVariables: () => {},
      setEnvSecrets: () => {},
      setConversationVariables: (v: any) => (this.wfState.conversationVariables = v),
      setSyncWorkflowDraftHash: (h: string) => (this.wfState.syncWorkflowDraftHash = h),
      setIsSyncingWorkflowDraft: (v: boolean) => (this.wfState.isSyncingWorkflowDraft = v),
      setIsWorkflowDataLoaded: (v: boolean) => (this.wfState.isWorkflowDataLoaded = v),
    }
    // initial canvas = initialNodes/initialEdges of the HTTP draft
    const nodes = initialNodesImpl(res.graph.nodes, res.graph.edges)
    const edges = initialEdgesImpl(res.graph.edges, res.graph.nodes)
    this.rf.nodes = nodes
    this.rf.edges = edges
    this.rf.viewport = res.graph.viewport ?? this.rf.viewport
    this.reactNodes = nodes
    this.reactEdges = edges
    this.loaded = true
    // --- instantiate the real hooks once (React would keep them stable across renders) ---
    const t0 = this
    this.manager = new R.CollaborationManager()
    this.wsClient = new R.WebSocketClient()
    const real = this.world.crdtRuntimeFor(this)
    instrumentManager(this.manager, { get cache() { return t0.fastCache } } as any, this.world.fast)
    this.manager.crdtRuntime = real // same injection Dify's own unit tests use (core/__tests__/test-crdt-runtime.ts)
    const sync = R.useNodesSyncDraftByCanEdit(true)
    this.hooksState = { ...sync }
    const refresh = R.useWorkflowRefreshDraft()
    this.hooksState.handleRefreshWorkflowDraft = refresh.handleRefreshWorkflowDraft
    this.hooks.refresh = refresh
    this.hooks.sync = R.useNodesSyncDraftWrapper()
    this.hooks.nodeData = R.useNodeDataUpdate()
    this.hooks.collab = R.useCollaborativeWorkflow()
    this.hooks.workflowUpdate = R.useWorkflowUpdate()
    this.mountWorkflowEffects()
    this.mountWorkflowMainEffects()
    // useCollaboration effect: collaborationManager.connect(appId, reactFlowStore)
    const t = this
    // workflow-main.tsx:71-79 passes `reactFlow.setNodes/setEdges` (the useReactFlow() INSTANCE methods) to the manager. In @reactflow/core 11.11.4
    // (dist/esm/index.mjs:1676-1700) the instance setNodes only acts when the store has `hasDefaultNodes` or an `onNodesChange` handler; Dify's <ReactFlow>
    // passes neither (index.tsx:768-787: nodes controlled, no onNodesChange; onEdgesChange=handleEdgesChange only forwards 'select' changes, helpers.ts:44).
    // So the manager's rAF import callbacks never write the canvas: the RF store changes only via the `graphImport` handler (2nd rAF) -> store.setNodes.
    const reactFlowStore = {
      getState: () => ({
        getNodes: () => t.rf.nodes,
        setNodes: (_n: any[]) => {},
        getEdges: () => t.rf.edges,
        setEdges: (_e: any[]) => {},
      }),
    }
    try {
      this.connectionId = await this.manager.connect(appId, reactFlowStore)
      if (this.world.fast.lazy && !this.noLazy) this.lazy = true
    } catch (e) {
      this.onUncaught(e, 'manager.connect')
    }
  }

  // ---- workflow/index.tsx effects (re-implemented; see FIDELITY.md "app shell") ----
  private mountWorkflowEffects() {
    const R = this.world.real
    const isEqual = R.isEqual
    const m = this.manager
    // index.tsx:271-285
    m.onGraphImport(({ nodes: importedNodes, edges: importedEdges }: any) => {
      this.graphImportCount++
      if (!isEqual(this.reactNodes, importedNodes)) {
        this.reactNodes = importedNodes
        this.rf.nodes = importedNodes
      }
      if (!isEqual(this.reactEdges, importedEdges)) {
        this.reactEdges = importedEdges
        this.rf.edges = importedEdges
      }
    })
    // index.tsx:351-367 WORKFLOW_DATA_UPDATE
    this.eventEmitterSubs.add((v: any) => {
      if (typeof v === 'object' && v.type === 'WORKFLOW_DATA_UPDATE') {
        const payload = v.payload
        this.reactNodes = payload.nodes
        this.rf.nodes = payload.nodes
        this.reactEdges = payload.edges
        this.rf.edges = payload.edges
        if (payload.hash) this.wfState.setSyncWorkflowDraftHash(payload.hash)
      }
    })
    // index.tsx:489-499 visibilitychange / beforeunload
    this.document.addEventListener('visibilitychange', this.handleSyncWorkflowDraftWhenPageClose)
  }

  // index.tsx:419-460 (verbatim control flow)
  handleSyncWorkflowDraftWhenPageClose = () => {
    const m = this.manager
    const syncWorkflowDraftWhenPageClose = this.hooksState.syncWorkflowDraftWhenPageClose
    if (this.visibility === 'hidden') {
      m.emitGraphViewState(false)
      syncWorkflowDraftWhenPageClose()
      return
    }
    if (this.visibility === 'visible') {
      m.emitGraphViewState(true)
      const { isListening, workflowRunningData } = this.wfState
      const status = workflowRunningData?.result?.status
      if (isListening || status === 'running') return
      const collaborationConnected = m.isConnected()
      if (collaborationConnected && !m.canRestoreGraphFromCrdt()) return
      if (collaborationConnected) {
        m.refreshGraphSynchronously()
        setTimeout(() => this.hooksState.handleRefreshWorkflowDraft(true), 500)
      } else {
        setTimeout(() => this.hooksState.handleRefreshWorkflowDraft(), 500)
      }
    }
  }
  // index.tsx:462-466
  handleBeforeUnload = () => {
    const m = this.manager
    if (m.canRestoreGraphFromCrdt()) m.refreshGraphSynchronously()
    this.hooksState.syncWorkflowDraftWhenPageClose()
  }

  // ---- workflow-app/components/workflow-main.tsx effects (re-implemented) ----
  private mountWorkflowMainEffects() {
    const m = this.manager
    const R = this.world.real
    const hs = this.hooksState
    // :290-310 onSyncRequest
    m.onSyncRequest(({ acknowledge }: any) => {
      if (!m.canPersistLocalGraph()) {
        acknowledge({ success: false, error: 'Collaborative graph is not ready to save.' })
        return
      }
      m.refreshGraphSynchronously()
      void hs
        .doSyncWorkflowDraft(false, undefined, { forceLocal: true })
        .then((result: any) => {
          acknowledge(result ? { success: true, hash: result.hash, updatedAt: result.updatedAt } : { success: false })
        })
        .catch(() => acknowledge({ success: false }))
    })
    // :258-276 onWorkflowUpdate (another user imported DSL / restored a version): replace canvas from the stored draft
    m.onWorkflowUpdate(async () => {
      try {
        const response = await this.world.httpFor(this).get(`/apps/${this.appId}/workflows/draft`)
        if (response.graph) this.hooks.workflowUpdate.handleUpdateWorkflowCanvas(response.graph)
      } catch (e) {
        void e
      }
    })
    // :312-345 onGraphReloadRequired
    let retryTimer: any
    let disposed = false
    m.onGraphReloadRequired(async (request: any) => {
      if (retryTimer) {
        clearTimeout(retryTimer)
        retryTimer = undefined
      }
      const isCurrent = () => !disposed && m.isGraphReloadCurrent(request)
      const refreshed = await hs.handleRefreshWorkflowDraft(false, { shouldApply: isCurrent })
      if (!isCurrent()) return
      if (refreshed) {
        m.replaceGraphFromReactFlow(request)
        return
      }
      const retryDelay = Math.min(1000 * 2 ** request.attempt, 30_000)
      retryTimer = setTimeout(() => {
        retryTimer = undefined
        m.retryGraphReload(request)
      }, retryDelay)
    })
    void R
  }

  /** SPA navigation away from the editor (React unmount of the route). Real data (repro S6D: 20/20 saved) shows the unmount save works, i.e.
   *  Workflow's `syncWorkflowDraftOnUnmount` (workflow/index.tsx:377-397) runs while the collaboration state is still intact; the tab's
   *  collaboration connection is torn down afterwards (use-collaboration cleanup -> manager.disconnect). */
  navigateAway() {
    if (this.dead) return
    this.flush(this.world.sim.now)
    this.world.sim.als.run(this, () => {
      const m = this.manager
      try {
        const { debouncedSyncWorkflowDraft, isWorkflowDataLoaded } = this.wfState
        if (isWorkflowDataLoaded) {
          debouncedSyncWorkflowDraft.cancel?.()
          if (m.canUseLocalDraftFallback()) this.hooksState.syncWorkflowDraftWhenPageClose()
          else if (m.canFlushGraphOnPageClose()) this.hooks.sync.handleSyncWorkflowDraft(true, true, {})
        }
        m.disconnect(this.connectionId)
      } catch (e) {
        this.onUncaught(e, 'navigateAway')
      }
    })
    this.socket?.disconnect()
    this.dead = true
  }

  /** Graceful tab close: beforeunload handlers run (keepalive save), then sockets are closed by the browser. */
  closeTab(graceful = true) {
    if (this.dead) return
    this.flush(this.world.sim.now)
    // Real data (repro S5A 20/20 lost with a second user online, S6A 20/20 saved single-user): on page close the visibilitychange->hidden handler
    // runs before the beforeunload save, so the hidden leader may only flush when it is alone in the room (canFlushGraphOnPageClose).
    if (graceful && this.loaded) this.setVisibility('hidden')
    this.world.sim.als.run(this, () => {
      if (graceful && this.loaded && this.manager) {
        try {
          this.handleBeforeUnload()
        } catch (e) {
          this.onUncaught(e, 'beforeunload')
        }
      }
    })
    this.dead = true
    const c = this.socket?.conn
    if (c) {
      // FIN travels up the same FIFO pipe, so everything emitted before the close arrives first.
      this.link.up.send(8, () => this.world.server.closeConn(c, 'transport close', false), null, 'up:fin')
      // a blackholed link never delivers the FIN -> the server only notices via ping timeout (handled by world.cutLink)
    }
  }
}
