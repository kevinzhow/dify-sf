// socket.io-client Socket + Manager behaviour (v4.8.3) as seen by Dify code, over the simulated network.
//  - emit() while disconnected is buffered (sendBuffer) and flushed BEFORE the 'connect' event handlers run (Socket.onconnect -> emitBuffered -> emitReserved('connect'))
//  - plain acks pending at disconnect are dropped silently (Socket._clearAcks only errors `.timeout()` acks)
//  - auto-reconnect with Manager defaults: reconnectionDelay 1000 ms, factor 2, randomizationFactor 0.5, reconnectionDelayMax 5000 ms, timeout 20000 ms
//  - manual disconnect() => reason 'io client disconnect', no reconnect
import type { Tab } from './tab'
import type { Conn } from './server'
import { wireCopy, wireSize } from './net'

type Handler = (...a: any[]) => void

export class FakeSocket {
  connected = false
  id: string | undefined = undefined
  private handlers = new Map<string, Set<Handler>>()
  private sendBuffer: { ev: string; args: any[]; ackId?: number }[] = []
  private acks = new Map<number, Handler>()
  private ackSeq = 1
  conn: Conn | null = null
  private skipReconnect = false
  private attempts = 0
  private connecting = false
  private reconnectTimer: { cancel(): void } | null = null
  private connectTimer: { cancel(): void } | null = null
  disconnectedReasons: string[] = []

  constructor(private tab: Tab) {
    // autoConnect: open() on next tick
    tab.world.sim.after(0, () => this.tryConnect())
  }

  // ---- public socket.io-client API used by Dify ----
  on(ev: string, fn: Handler) {
    if (!this.handlers.has(ev)) this.handlers.set(ev, new Set())
    this.handlers.get(ev)!.add(fn)
    return this
  }
  off(ev?: string, fn?: Handler) {
    if (!ev) {
      this.handlers.clear()
      return this
    }
    if (fn) this.handlers.get(ev)?.delete(fn)
    else this.handlers.delete(ev)
    return this
  }
  emit(ev: string, ...args: any[]) {
    let ack: Handler | undefined
    if (typeof args[args.length - 1] === 'function') ack = args.pop()
    const ackId = ack ? this.ackSeq++ : undefined
    if (ack && ackId !== undefined) this.acks.set(ackId, ack)
    if (this.connected) this.packet(ev, args, ackId)
    else this.sendBuffer.push({ ev, args, ackId })
    return this
  }
  disconnect() {
    if (this.connected) {
      this.packet('__disconnect', [], undefined)
      this.onclose('io client disconnect', false)
    } else {
      this.cancelPending()
      this.sendBuffer = []
    }
    this.skipReconnect = true
    return this
  }
  connect() {
    this.skipReconnect = false
    if (!this.connected && !this.connecting) this.tryConnect()
    return this
  }

  // ---- internals ----
  private fire(ev: string, ...args: any[]) {
    const hs = this.handlers.get(ev)
    if (!hs) return
    for (const h of [...hs]) {
      try {
        h(...args)
      } catch (e) {
        this.tab.onUncaught(e, `socket handler ${ev}`)
      }
    }
  }
  private packet(ev: string, args: any[], ackId?: number) {
    const conn = this.conn
    if (!conn) return
    const srv = this.tab.world.server
    const payload = wireCopy(args)
    const size = wireSize(payload) + ev.length + 8
    this.tab.stats.bytesUp += size
    if (ev === 'graph_event' || ev === 'collaboration_event') this.tab.world.tr(this.tab.name, 'SEND ' + ev + (ev === 'collaboration_event' ? ':' + (args[0]?.type ?? '') : ''), `${size}B`)
    this.tab.link.up.send(
      size,
      () => {
        if (ev === '__disconnect') return srv.closeConn(conn, 'client namespace disconnect', false)
        if (ev === '__ack') return srv.onAck(conn, args[0], args.slice(1))
        srv.onPacket(conn, ev, payload, ackId, size)
      },
      null,
      'up:' + ev,
    )
  }
  sendAck(ackId: number, res: any[]) {
    this.packet('__ack', [ackId, ...res])
  }

  private cancelPending() {
    this.reconnectTimer?.cancel()
    this.connectTimer?.cancel()
    this.reconnectTimer = this.connectTimer = null
    this.connecting = false
  }

  /** manager.open(): websocket handshake. */
  private tryConnect() {
    const tab = this.tab
    if (tab.dead || this.connected || this.connecting || this.skipReconnect) return
    this.connecting = true
    const sim = tab.world.sim
    const link = tab.link
    const hs = (link.cfg.upMs + link.cfg.downMs) * 1.5 + 30
    if (link.mode === 'down') {
      // connection refused
      this.connectTimer = sim.after(Math.max(5, link.cfg.upMs), () => this.onConnectError(new Error('xhr poll error')), tab)
      return
    }
    if (link.mode === 'blackhole') {
      this.connectTimer = sim.after(20000, () => this.onConnectError(new Error('timeout')), tab)
      return
    }
    this.connectTimer = sim.after(hs, () => {
      this.connecting = false
      if (link.mode !== 'up') return this.onConnectError(new Error('handshake interrupted'))
      const conn = tab.world.server.accept(tab, { user_id: tab.user.id, username: tab.user.name, avatar: null, tenant_id: 't1' })
      this.conn = conn
      tab.connId = conn.id
      this.id = conn.sid
      this.connected = true
      this.attempts = 0
      tab.world.server.trace(`${tab.name} connected sid=${conn.sid}`)
      // Socket.onconnect: emitBuffered() BEFORE emitReserved('connect')
      const buf = this.sendBuffer
      this.sendBuffer = []
      for (const p of buf) this.packet(p.ev, p.args, p.ackId)
      this.fire('connect')
    }, tab)
  }
  private onConnectError(err: Error) {
    this.connecting = false
    this.fire('connect_error', err)
    this.scheduleReconnect()
  }
  private scheduleReconnect() {
    if (this.skipReconnect || this.tab.dead) return
    const ms0 = 1000 * 2 ** this.attempts
    this.attempts++
    const rand = this.tab.world.sim.rng.next()
    const dev = Math.floor(rand * 0.5 * ms0)
    let ms = (Math.floor(rand * 10) & 1) === 0 ? ms0 - dev : ms0 + dev
    ms = Math.min(ms, 5000) | 0
    this.reconnectTimer = this.tab.world.sim.after(ms, () => this.tryConnect(), this.tab)
  }

  /** transport/engine closed */
  onclose(reason: string, reconnect = true) {
    if (!this.connected && !this.conn) return
    this.connected = false
    this.id = undefined
    const old = this.conn
    this.conn = null
    // _clearAcks: drop plain acks that are not still buffered
    const buffered = new Set(this.sendBuffer.map((p) => p.ackId))
    for (const k of [...this.acks.keys()]) if (!buffered.has(k)) this.acks.delete(k)
    this.disconnectedReasons.push(reason)
    this.tab.world.server.trace(`${this.tab.name} disconnect(${reason}) sid=${old?.sid}`)
    this.fire('disconnect', reason)
    if (reconnect && reason !== 'io server disconnect' && reason !== 'io client disconnect') this.scheduleReconnect()
  }

  // ---- delivery from server (called by Tab as ServerTab) ----
  deliver(ev: string, args: any[], ackId?: number) {
    if (ev === '__ack') {
      const id = args[0] as number
      const cb = this.acks.get(id)
      if (cb) {
        this.acks.delete(id)
        try {
          cb(...args.slice(1))
        } catch (e) {
          this.tab.onUncaught(e, 'ack handler')
        }
      }
      return
    }
    if (ev === 'graph_update') this.tab.world.tr(this.tab.name, 'RECV graph_update (CRDT import)', '')
    const full = ackId !== undefined ? [...args, (...res: any[]) => this.sendAck(ackId, res)] : args
    this.fire(ev, ...full)
  }
}
