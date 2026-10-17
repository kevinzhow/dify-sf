// Port of the Dify backend pieces on the collaboration path (api/ @ 1.17.1):
//   controllers/console/socketio/workflow.py          -> DifyServer.onEvent (socket.io event handlers)
//   services/workflow_collaboration_service.py        -> WorkflowCollaborationService (same method names / control flow)
//   repositories/workflow_collaboration_repository.py -> Redis (in-memory)
//   services/workflow_service.py:sync_draft_workflow  -> DraftDb.sync (hash check + graph_only)
//   controllers/console/app/workflow.py:DraftWorkflowApi -> http handlers
// python-socketio room/ack/call semantics are re-implemented over the simulated network (net.ts).
import type { Sim } from './core'
import { Link, wireCopy, wireSize } from './net'
import { Rng } from './rng'
import { uniqueHash } from './pyjson'

export const SYNC_REQUEST_TIMEOUT_MS = 15_000 // workflow_collaboration_service.py:21
export const WEBSOCKET_MAX_HTTP_BUFFER_SIZE = 10 * 1024 * 1024 // configs/feature/__init__.py:596 default 10 MiB

export type SessionInfo = {
  user_id: string
  username: string
  avatar: string | null
  sid: string
  connected_at: number
  server_id: string
  graph_active: boolean
  graph_active_sequence?: number
}

export interface ServerTab {
  dead: boolean
  link: Link
  onServerPacket(connId: number, ev: string, args: any[], ackId?: number): void
  onServerAck(connId: number, ackId: number, args: any[]): void
  onServerClose(connId: number, reason: string): void
}

export class Conn {
  rooms = new Set<string>()
  open = true
  identity: { user_id: string; username: string; avatar: string | null; tenant_id: string } | null = null
  constructor(public sid: string, public id: number, public tab: ServerTab) {}
}

class Redis {
  sessions = new Map<string, Map<string, SessionInfo>>() // workflow_online_users:<wf> hash (insertion ordered == listpack order)
  sidMap = new Map<string, { workflow_id: string; user_id: string; server_id: string }>() // ws_sid_map:<sid>
  leader = new Map<string, string>() // workflow_leader:<wf>
  ops = 0
}

type Resp = [Record<string, unknown>, number]

export class DifyServer {
  conns = new Map<string, Conn>()
  rooms = new Map<string, Set<string>>()
  redis = new Redis()
  serverId = 'srv-1'
  nextSid = 1
  nextConn = 1
  pendingCalls = new Map<string, { resolve: (v: unknown) => void; reject: (e: Error) => void; timer: { cancel(): void } }>()
  ackSeq = 1
  // observability
  stats = {
    eventsIn: {} as Record<string, number>,
    bytesIn: 0,
    bytesOut: 0,
    graphEventBytes: 0,
    graphUpdatesOut: 0,
    oversizeKicks: 0,
    syncRequests: 0,
    syncOk: 0,
    syncFail: 0,
    syncTimeout: 0,
    leaderChanges: 0,
    sessionsPruned: 0,
  }
  log: { t: number; msg: string }[] = []
  keepLog = false
  db = new DraftDb(this)
  procSeq: Record<string, number[]> | null = null // calibration replay: measured server+proxy delay per graph_event, per sending tab, consumed in order
  proc = { eventMs: 0.4 } // per-event handler cost; python-socketio handler + ~8 Redis round trips at ~50us on localhost docker

  constructor(public sim: Sim, public rng: Rng) {}

  trace(msg: string) {
    if (this.keepLog) this.log.push({ t: this.sim.now, msg })
  }

  // ------------------------------------------------------------------ transport glue
  /** python-socketio connect handler (socket_connect): auth succeeds for every simulated user. */
  accept(tab: ServerTab, identity: Conn['identity']): Conn {
    const sid = `sid${(this.nextSid++).toString(36)}${this.rng.hex(6)}`
    const c = new Conn(sid, this.nextConn++, tab)
    c.identity = identity
    this.conns.set(sid, c)
    return c
  }

  private sendTo(c: Conn, ev: string, args: any[], ackId?: number) {
    if (!c.open || c.tab.dead) return
    const payload = wireCopy(args, 'arraybuffer', true)
    const size = wireSize(payload) + ev.length + 8
    this.stats.bytesOut += size
    if (ev === 'graph_update') {
      this.stats.graphUpdatesOut++
    }
    c.tab.link.down.send(size, () => c.tab.onServerPacket(c.id, ev, payload, ackId), c.tab, 'down:' + ev)
  }
  emitTo(sid: string, ev: string, payload: unknown, ackId?: number) {
    const c = this.conns.get(sid)
    if (!c) return
    this.sendTo(c, ev, [payload], ackId)
  }
  emitRoom(room: string, ev: string, payload: unknown, skipSid?: string) {
    const r = this.rooms.get(room)
    if (!r) return
    for (const sid of r) {
      if (sid === skipSid) continue
      this.emitTo(sid, ev, payload)
    }
  }
  /** sio.call(): emit with ack, reject on timeout */
  call(sid: string, ev: string, payload: unknown, timeoutMs: number): Promise<unknown> {
    const c = this.conns.get(sid)
    return new Promise((resolve, reject) => {
      const ackId = this.ackSeq++
      const key = `${sid}:${ackId}`
      const timer = this.sim.after(timeoutMs, () => {
        this.pendingCalls.delete(key)
        reject(new Error('SocketIOTimeoutError'))
      }, null)
      this.pendingCalls.set(key, { resolve, reject, timer })
      if (c) this.sendTo(c, ev, [payload], ackId)
    })
  }

  /** client -> server packet arrival (called by the FakeSocket pipe after the uplink delay) */
  onPacket(c: Conn, ev: string, args: any[], ackId: number | undefined, size: number) {
    if (!c.open) return
    this.stats.bytesIn += size
    this.stats.eventsIn[ev] = (this.stats.eventsIn[ev] ?? 0) + 1
    if (size > WEBSOCKET_MAX_HTTP_BUFFER_SIZE) {
      // engineio: packet larger than max_http_buffer_size -> the websocket is closed
      this.stats.oversizeKicks++
      this.trace(`oversize packet ${ev} ${size}B from ${c.sid}: closing`)
      this.closeConn(c, 'transport error', true)
      return
    }
    const ack = (...res: any[]) => {
      if (ackId === undefined) return
      this.sendTo(c, '__ack', [ackId, ...res], undefined)
    }
    // handler cost delays the response (not the ordering of arrival)
    const run = () => {
      if (!c.open && ev !== 'disconnect') return
      this.dispatch(c, ev, args, ack)
    }
    let eventMs = this.proc.eventMs
    if (ev === 'graph_event' && this.procSeq) {
      const q = this.procSeq[(c.tab as any).name]
      if (q && q.length) eventMs = q.shift()!
    }
    if (eventMs > 0) this.sim.after(eventMs, run, null)
    else run()
  }

  /** ack packet from a client for a server-initiated call */
  onAck(c: Conn, ackId: number, args: any[]) {
    const key = `${c.sid}:${ackId}`
    const p = this.pendingCalls.get(key)
    if (!p) return
    this.pendingCalls.delete(key)
    p.timer.cancel()
    p.resolve(args.length <= 1 ? args[0] : args)
  }

  /** transport closed (client closed / ping timeout / server kicked) */
  closeConn(c: Conn, reason: string, notifyClient: boolean) {
    if (!c.open) return
    c.open = false
    if (notifyClient && !c.tab.dead) {
      c.tab.link.down.send(32, () => c.tab.onServerClose(c.id, reason), c.tab, 'down:close')
    }
    // python-socketio: leave all rooms, then fire 'disconnect' handler
    for (const r of c.rooms) this.rooms.get(r)?.delete(c.sid)
    c.rooms.clear()
    this.conns.delete(c.sid)
    try {
      this.svc.disconnect_session(c.sid)
    } catch (e) {
      this.trace('disconnect handler error ' + e)
    }
  }
  isConnected(sid: string) {
    return this.conns.has(sid)
  }
  enterRoom(sid: string, room: string) {
    const c = this.conns.get(sid)
    if (!c) return
    c.rooms.add(room)
    if (!this.rooms.has(room)) this.rooms.set(room, new Set())
    this.rooms.get(room)!.add(sid)
  }

  svc = new WorkflowCollaborationService(this)

  private dispatch(c: Conn, ev: string, args: any[], ack: (...r: any[]) => void) {
    const data = args[0]
    switch (ev) {
      case 'user_connect': {
        const wf = data?.workflow_id
        if (!wf) return ack({ msg: 'workflow_id is required' }, 400)
        const r = this.svc.authorize_and_join_workflow_room(wf, c.sid)
        if (!r) return ack({ msg: 'unauthorized' }, 401)
        return ack({ msg: 'connected', user_id: r[0], sid: c.sid, isLeader: r[1] })
      }
      case 'collaboration_event': {
        void this.svc.relay_collaboration_event(c.sid, data).then(([body, status]) => ack(body, status))
        return
      }
      case 'graph_event': {
        this.stats.graphEventBytes += data instanceof Uint8Array || data instanceof ArrayBuffer ? (data as any).byteLength : 0
        const [body, status] = this.svc.relay_graph_event(c.sid, data)
        return ack(body, status)
      }
      default:
        return ack()
    }
  }
}

// =====================================================================================================================
// services/workflow_collaboration_service.py (control flow kept 1:1; method names identical)
// =====================================================================================================================
export class WorkflowCollaborationService {
  constructor(private s: DifyServer) {}
  private get r() {
    return this.s.redis
  }
  private now_s() {
    return Math.floor((1_800_000_000_000 + this.s.sim.now) / 1000)
  }

  authorize_and_join_workflow_room(workflow_id: string, sid: string): [string, boolean] | null {
    const conn = this.s.conns.get(sid)
    const id = conn?.identity
    if (!id) return null
    const session_info: SessionInfo = {
      user_id: id.user_id,
      username: id.username,
      avatar: id.avatar,
      sid,
      connected_at: this.now_s(),
      server_id: this.s.serverId,
      graph_active: true,
    }
    this.set_session_info(workflow_id, session_info)
    const leader_sid = this.get_or_set_leader(workflow_id, sid)
    const is_leader = leader_sid === sid
    this.s.enterRoom(sid, workflow_id)
    this.broadcast_online_users(workflow_id)
    this.s.emitTo(sid, 'status', { isLeader: is_leader })
    return [id.user_id, is_leader]
  }

  disconnect_session(sid: string) {
    const mapping = this.get_sid_mapping(sid)
    if (!mapping) return
    const workflow_id = mapping.workflow_id
    this.delete_session(workflow_id, sid)
    this.handle_leader_disconnect(workflow_id, sid)
    this.broadcast_online_users(workflow_id)
  }

  async relay_collaboration_event(sid: string, data: any): Promise<Resp> {
    const mapping = this.get_sid_mapping(sid)
    if (!mapping) return [{ msg: 'unauthorized' }, 401]
    const workflow_id = mapping.workflow_id
    const user_id = mapping.user_id
    this.refresh_session_state(workflow_id, sid)

    const event_type = data?.type
    const event_data = data?.data
    const timestamp = data?.timestamp ?? this.now_s()
    if (!event_type) return [{ msg: 'invalid event type' }, 400]

    if (event_type === 'graph_view_state') {
      if (typeof event_data !== 'object' || event_data === null) return [{ msg: 'invalid graph_view_state' }, 400]
      const graph_active = event_data.graphActive
      const sequence = event_data.sequence
      if (typeof graph_active !== 'boolean') return [{ msg: 'invalid graph_view_state' }, 400]
      if (!Number.isInteger(sequence) || sequence < 0) return [{ msg: 'invalid graph_view_state' }, 400]
      // `with graph_view_state_lock(workflow_id)`: handlers here are atomic (no yield between the Lua write and the demotion)
      const applied = this.update_session_graph_active(workflow_id, sid, graph_active, sequence)
      if (!applied) return [{ msg: 'graph_view_state_ignored' }, 200]
      if (!graph_active) this._demote_leader_if_hidden(workflow_id, sid)
      return [{ msg: 'graph_view_state_updated' }, 200]
    }

    if (event_type === 'sync_request') {
      this.s.stats.syncRequests++
      if (typeof event_data !== 'object' || event_data === null) return [{ msg: 'invalid sync_request' }, 400]
      const request_id = event_data.requestId
      if (typeof request_id !== 'string' || !request_id.trim()) return [{ msg: 'invalid sync_request' }, 400]

      const leader_sid = this.get_current_leader_raw(workflow_id)
      let target_sid: string | null
      if (leader_sid && this.is_session_active(workflow_id, leader_sid)) {
        if (this._is_session_graph_active(workflow_id, leader_sid)) {
          target_sid = leader_sid
        } else {
          const replacement = this._select_graph_leader(workflow_id, sid)
          if (replacement && replacement !== leader_sid) {
            this.set_leader(workflow_id, replacement)
            this.broadcast_leader_change(workflow_id, replacement)
            target_sid = replacement
          } else {
            target_sid = leader_sid
          }
        }
      } else {
        if (leader_sid) this.delete_leader(workflow_id)
        target_sid = this._select_graph_leader(workflow_id, sid)
        if (target_sid) {
          this.set_leader(workflow_id, target_sid)
          this.broadcast_leader_change(workflow_id, target_sid)
        }
      }
      if (!target_sid) return [{ msg: 'no_active_leader', requestId: request_id }, 503]

      const target_data = { ...event_data, requestId: request_id }
      let result: any
      try {
        result = await this.s.call(
          target_sid,
          'collaboration_update',
          { type: event_type, userId: user_id, data: target_data, timestamp },
          SYNC_REQUEST_TIMEOUT_MS,
        )
      } catch {
        this.s.stats.syncTimeout++
        this.s.trace(`sync_request timeout requester=${sid} target=${target_sid}`)
        return [{ msg: 'sync_request_timeout', requestId: request_id }, 504]
      }
      if (typeof result !== 'object' || result === null || result.success !== true) {
        this.s.stats.syncFail++
        const response: Record<string, unknown> = { msg: 'workflow_sync_failed', requestId: request_id, success: false }
        if (result && typeof result === 'object' && typeof result.error === 'string') response.error = result.error
        return [response, 502]
      }
      const workflow_hash = result.hash
      const updated_at = result.updatedAt
      if (typeof workflow_hash !== 'string' || !workflow_hash) return [{ msg: 'invalid_sync_response', requestId: request_id }, 502]
      if (!Number.isInteger(updated_at)) return [{ msg: 'invalid_sync_response', requestId: request_id }, 502]
      this.s.stats.syncOk++
      return [{ msg: 'workflow_synced', requestId: request_id, success: true, hash: workflow_hash, updatedAt: updated_at }, 200]
    }

    if (event_type === 'graph_resync_request') {
      const leader_sid = this.get_current_leader_raw(workflow_id)
      let resync_target_sid: string | null
      if (leader_sid && this.is_session_active(workflow_id, leader_sid)) {
        resync_target_sid = leader_sid
      } else {
        if (leader_sid) this.delete_leader(workflow_id)
        resync_target_sid = this._select_graph_leader(workflow_id, sid)
        if (resync_target_sid) {
          this.set_leader(workflow_id, resync_target_sid)
          this.broadcast_leader_change(workflow_id, resync_target_sid)
        }
      }
      if (!resync_target_sid) return [{ msg: 'no_active_leader' }, 503]
      this.s.emitTo(resync_target_sid, 'collaboration_update', { type: event_type, userId: user_id, data: event_data, timestamp })
      return [{ msg: 'graph_resync_request_forwarded' }, 200]
    }

    this.s.emitRoom(workflow_id, 'collaboration_update', { type: event_type, userId: user_id, data: event_data, timestamp }, sid)
    return [{ msg: 'event_broadcasted' }, 200]
  }

  relay_graph_event(sid: string, data: unknown): Resp {
    const mapping = this.get_sid_mapping(sid)
    if (!mapping) return [{ msg: 'unauthorized' }, 401]
    const workflow_id = mapping.workflow_id
    this.refresh_session_state(workflow_id, sid)
    this.s.emitRoom(workflow_id, 'graph_update', data, sid)
    return [{ msg: 'graph_update_broadcasted' }, 200]
  }

  get_or_set_leader(workflow_id: string, sid: string): string {
    let current_leader = this.get_current_leader_raw(workflow_id)
    if (current_leader) {
      if (this.is_session_active(workflow_id, current_leader)) return current_leader
      this.delete_session(workflow_id, current_leader)
      this.delete_leader(workflow_id)
    }
    const was_set = this.set_leader_if_absent(workflow_id, sid)
    if (was_set) {
      if (current_leader) this.broadcast_leader_change(workflow_id, sid)
      return sid
    }
    current_leader = this.get_current_leader_raw(workflow_id)
    if (current_leader) return current_leader
    return sid
  }

  handle_leader_disconnect(workflow_id: string, disconnected_sid: string) {
    const current_leader = this.get_current_leader_raw(workflow_id)
    if (!current_leader) return
    if (current_leader !== disconnected_sid) return
    const new_leader_sid = this._select_graph_leader(workflow_id)
    if (new_leader_sid) {
      this.set_leader(workflow_id, new_leader_sid)
      this.broadcast_leader_change(workflow_id, new_leader_sid)
    } else {
      this.delete_leader(workflow_id)
    }
  }

  broadcast_leader_change(workflow_id: string, new_leader_sid: string | null) {
    this.s.stats.leaderChanges++
    for (const sid of this.get_session_sids(workflow_id)) {
      const is_leader = new_leader_sid !== null && sid === new_leader_sid
      this.s.emitTo(sid, 'status', { isLeader: is_leader })
    }
  }

  _prune_inactive_sessions(workflow_id: string): SessionInfo[] {
    const sessions = this.list_sessions(workflow_id)
    if (!sessions.length) return []
    const active: SessionInfo[] = []
    const stale: string[] = []
    for (const session of sessions) {
      if (this.is_session_active(workflow_id, session.sid)) active.push(session)
      else stale.push(session.sid)
    }
    for (const sid of stale) {
      this.s.stats.sessionsPruned++
      this.delete_session(workflow_id, sid)
    }
    return active
  }

  broadcast_online_users(workflow_id: string) {
    const users = this._prune_inactive_sessions(workflow_id)
    users.sort((a, b) => (a.connected_at || 0) - (b.connected_at || 0)) // python sort is stable; so is Array.sort
    let leader_sid = this.get_current_leader_raw(workflow_id)
    const previous_leader = leader_sid
    const active_sids = new Set(users.map((u) => u.sid))
    if (leader_sid && !active_sids.has(leader_sid)) {
      this.delete_leader(workflow_id)
      leader_sid = null
    }
    if (!leader_sid && users.length) {
      leader_sid = this._select_graph_leader(workflow_id)
      if (leader_sid) this.set_leader(workflow_id, leader_sid)
    }
    if (leader_sid !== previous_leader) this.broadcast_leader_change(workflow_id, leader_sid)
    this.s.emitRoom(workflow_id, 'online_users', {
      workflow_id,
      users: users.map((u) => ({ user_id: u.user_id, username: u.username, avatar: u.avatar, sid: u.sid, connected_at: u.connected_at, graph_active: u.graph_active })),
      leader: leader_sid,
    })
  }

  refresh_session_state(workflow_id: string, sid: string) {
    this._ensure_leader(workflow_id, sid)
  }

  _ensure_leader(workflow_id: string, sid: string) {
    const current_leader = this.get_current_leader_raw(workflow_id)
    if (current_leader && this.is_session_active(workflow_id, current_leader)) return // expire_leader (TTL only)
    if (current_leader) this.delete_leader(workflow_id)
    this.set_leader(workflow_id, sid)
    this.broadcast_leader_change(workflow_id, sid)
  }

  _select_graph_leader(workflow_id: string, preferred_sid: string | null = null, require_graph_active = false): string | null {
    const active_sessions = this.list_sessions(workflow_id).filter((s) => this.is_session_active(workflow_id, s.sid))
    const visible = active_sessions.filter((s) => s.graph_active !== false).map((s) => s.sid)
    let candidates = visible
    if (!candidates.length && !require_graph_active) candidates = active_sessions.map((s) => s.sid)
    if (!candidates.length) return null
    if (preferred_sid && candidates.includes(preferred_sid)) return preferred_sid
    return candidates[0]!
  }

  _is_session_graph_active(workflow_id: string, sid: string): boolean {
    const info = this.r.sessions.get(workflow_id)?.get(sid)
    if (!info) return true
    return !!(typeof info.graph_active === 'boolean' ? info.graph_active : true)
  }

  _demote_leader_if_hidden(workflow_id: string, hidden_sid: string) {
    const current_leader = this.get_current_leader_raw(workflow_id)
    if (current_leader !== hidden_sid) return
    const new_leader = this._select_graph_leader(workflow_id, null, true)
    if (!new_leader || new_leader === hidden_sid) return
    this.set_leader(workflow_id, new_leader)
    this.broadcast_leader_change(workflow_id, new_leader)
  }

  is_session_active(workflow_id: string, sid: string): boolean {
    if (!sid) return false
    const mapping = this.get_sid_mapping(sid)
    if (!mapping) return false
    if (!this.session_exists(workflow_id, sid)) return false
    return this.s.isConnected(sid) // server_id == self.server_id -> _is_socket_connected_locally
  }

  // ---- repository (Redis) ----
  get_sid_mapping(sid: string) {
    return this.r.sidMap.get(sid) ?? null
  }
  set_session_info(workflow_id: string, info: SessionInfo) {
    if (!this.r.sessions.has(workflow_id)) this.r.sessions.set(workflow_id, new Map())
    // HSET on an existing field keeps its position; a new field appends
    this.r.sessions.get(workflow_id)!.set(info.sid, info)
    this.r.sidMap.set(info.sid, { workflow_id, user_id: info.user_id, server_id: info.server_id })
  }
  delete_session(workflow_id: string, sid: string) {
    this.r.sessions.get(workflow_id)?.delete(sid)
    this.r.sidMap.delete(sid)
  }
  session_exists(workflow_id: string, sid: string) {
    return !!this.r.sessions.get(workflow_id)?.has(sid)
  }
  get_session_sids(workflow_id: string): string[] {
    return [...(this.r.sessions.get(workflow_id)?.keys() ?? [])]
  }
  list_sessions(workflow_id: string): SessionInfo[] {
    return [...(this.r.sessions.get(workflow_id)?.values() ?? [])]
  }
  update_session_graph_active(workflow_id: string, sid: string, active: boolean, sequence: number): boolean {
    const info = this.r.sessions.get(workflow_id)?.get(sid)
    if (!info) return false // Lua: HGET nil -> 0
    const current = info.graph_active_sequence
    if (current !== undefined && sequence <= current) return false
    info.graph_active = active
    info.graph_active_sequence = sequence
    return true
  }
  get_current_leader_raw(workflow_id: string): string | null {
    return this.r.leader.get(workflow_id) ?? null
  }
  set_leader_if_absent(workflow_id: string, sid: string) {
    if (this.r.leader.has(workflow_id)) return false
    this.r.leader.set(workflow_id, sid)
    return true
  }
  set_leader(workflow_id: string, sid: string) {
    this.r.leader.set(workflow_id, sid)
  }
  delete_leader(workflow_id: string) {
    this.r.leader.delete(workflow_id)
  }
}

// =====================================================================================================================
// Draft persistence: DraftWorkflowApi.post -> WorkflowService.sync_draft_workflow
// =====================================================================================================================
export type DraftResp = { status: number; body: any }

export class DraftDb {
  graph: any = null // json.loads(workflow.graph)
  updatedAt = 0
  saves: { t: number; by: string; hash: string; nodes: number; collaborative: boolean; ok: boolean; sentHash: string | null }[] = []
  hashCache: string | null = null
  constructor(private srv: DifyServer) {}
  seed(graph: any) {
    this.graph = JSON.parse(JSON.stringify(graph))
    this.updatedAt = Math.floor((1_800_000_000_000 + this.srv.sim.now) / 1000)
    this.hashCache = null
  }
  get hash(): string {
    return (this.hashCache ??= uniqueHash(this.graph))
  }
  get(): DraftResp {
    return { status: 200, body: { graph: JSON.parse(JSON.stringify(this.graph)), hash: this.hash, updated_at: this.updatedAt } }
  }
  /** sync_draft_workflow: `if workflow and workflow.unique_hash != unique_hash: raise WorkflowHashNotEqualError` -> 409 draft_workflow_not_sync.
   *  graph_only (collaborative) leaves features/variables alone; irrelevant for the graph itself. */
  post(body: any, by: string): DraftResp {
    const nodes = body?.graph?.nodes?.length ?? 0
    if (this.graph && this.hash !== body.hash) {
      this.saves.push({ t: this.srv.sim.now, by, hash: this.hash, nodes, collaborative: !!body._is_collaborative, ok: false, sentHash: body.hash ?? null })
      return { status: 409, body: { code: 'draft_workflow_not_sync', message: 'Workflow graph might have been modified, please refresh and resubmit.', status: 409 } }
    }
    this.graph = JSON.parse(JSON.stringify(body.graph))
    this.hashCache = null
    this.updatedAt = Math.floor((1_800_000_000_000 + this.srv.sim.now) / 1000)
    const h = this.hash
    this.saves.push({ t: this.srv.sim.now, by, hash: h, nodes, collaborative: !!body._is_collaborative, ok: true, sentHash: body.hash ?? null })
    return { status: 200, body: { result: 'success', hash: h, updated_at: this.updatedAt } }
  }
}
