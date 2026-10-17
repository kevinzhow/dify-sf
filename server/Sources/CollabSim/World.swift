import CollabCore
import CollabInvariants

public struct Stats: Sendable {
    public private(set) var counters: [String: Int] = [:]
    public init() {}
    mutating func bump(_ key: String, _ n: Int = 1) { counters[key, default: 0] += n }
    public subscript(key: String) -> Int { counters[key] ?? 0 }
    public mutating func merge(_ other: Stats) {
        for (k, v) in other.counters { counters[k, default: 0] += v }
    }
}

/// What the simulator records about the run (the protocol itself does not retain it).
public struct Record: Sendable {
    public var initial: Document
    public var issued: [OpKey: Issued] = [:]
    public var terminals: [OpKey: [Terminal]] = [:]
    /// Edits the client refused before sending (the user is told why): (client, reason).
    public var localRefusals: [(ClientID, String)] = []
    public var sameValueOps: Set<OpKey> = []
    public var violations: [String] = []
    public var stats = Stats()
}

struct Packet: Sendable {
    enum Payload: Sendable {
        case post(SubmitRequest)
        case open(StreamOpen, conn: Int)
        case response(SubmitResponse)
        case event(StreamEvent, generation: Int)
        /// The server ended the stream of this generation (after the events sent before it).
        case streamEnd(generation: Int)
    }
    var at: Int
    var tie: Int
    var slot: Int
    var slotEpoch: Int
    var serverEpoch: Int
    var payload: Payload
}

public struct Slot: Sendable {
    public let id: ClientID
    public let journaled: Bool
    /// Plays a client older than protocol 1.6: no `proto` on its stream, never restores.
    public var legacy = false
    public var client: Client?
    var durable: ClientDurable?
    public var linkUp = true
    var epoch = 0
    var streamClock = 0
    var restartAt: Int?
    var linkRestoreAt: Int?
    var reconnectAt: Int?
    var reapplyQueue: [Op] = []
    /// The node (as this user saw it) and its edges for each of its pending deletes, by cseq: what an undo restores.
    var deleteMemo: [Int: (node: Node, edges: [Edge])] = [:]
}

/// One simulated deployment: a server, N clients, a lossy reordering network and a fault injector.
/// Entirely deterministic given (config, seed). Scenario tests drive it by hand through the public
/// methods; the fuzzer drives it with `step()`.
///
/// Network model (mirrors HTTP + SSE): POST requests/responses and stream-open requests are independent
/// packets that can be delayed, reordered, lost and duplicated. Stream events are FIFO per connection and
/// never lost individually (TCP); a connection can only die as a whole (link drop, server crash).
public struct World: Sendable {
    public let cfg: SimConfig
    public private(set) var rng: Rng
    public private(set) var now = 0
    var server: SimServer?
    var serverDisk: SimDisk
    public private(set) var slots: [Slot] = []
    public var rec: Record

    public var traceLog: [String] = []
    public var traceEnabled = false
    private var packets: [Packet] = []
    private var tie = 0
    private var serverEpoch = 0
    private var serverRestartAt: Int?
    private var preCrash: (doc: Document, seq: Int)?
    private var calm = false
    private var nodeCounter = 0
    private var edgeCounter = 0
    private var itemCounter = 0
    private var connCounter = 0
    private let clientConfig = ClientConfig(retransmitAfter: 8, streamSilence: 35, reconnectBase: 2, reconnectMax: 24, maxBatch: 8)
    /// Committed deletes that can be undone: the node as its deleter saw it, its edges, and who deleted it.
    private var restorable: [NodeID: (node: Node, edges: [Edge], by: ClientID)] = [:]

    private func config(legacy: Bool) -> ClientConfig {
        var c = clientConfig
        if legacy { c.proto = nil }
        return c
    }

    public init(seed: UInt64, cfg: SimConfig, initial: Document? = nil, clientIDs: [ClientID]? = nil) {
        self.cfg = cfg
        var rng = Rng(seed: seed)
        var doc = initial ?? Document()
        if initial == nil {
            for i in 0..<cfg.initialNodes {
                doc.apply(.addNode(Node(id: "n\(i)", type: i == 0 ? "start" : "llm", title: "Node \(i)",
                                        x: i * 100, y: 0, config: ["prompt": .string("p\(i)")])),
                          at: Stamp(seq: 0, client: "genesis"))
            }
        }
        // The genesis stamps use seq 0, which is never > any base, so they can never conflict.
        rec = Record(initial: doc)
        serverDisk = SimDisk(initial: doc)
        server = try! SimServer(disk: serverDisk, snapshotEvery: cfg.snapshotEvery, maxReplay: cfg.maxReplay, defects: cfg.defects)
        nodeCounter = cfg.initialNodes
        let ids = clientIDs ?? (0..<cfg.clientCount).map { "c\($0)" }
        for (k, id) in ids.enumerated() {
            let journaled = !rng.chance(cfg.volatileFraction)
            let legacy = (cfg.legacyFraction > 0 && rng.chance(cfg.legacyFraction)) || cfg.legacySlots.contains(k)
            var cc = clientConfig
            if legacy { cc.proto = nil }
            var slot = Slot(id: id, journaled: journaled, client: Client(id: id, journaled: journaled, defects: cfg.defects, config: cc))
            slot.legacy = legacy
            slots.append(slot)
        }
        self.rng = rng
        for i in slots.indices { boot(i) }
    }

    /// Head of the live server (nil while it is down).
    public var serverSeq: Int? { server?.seqr.seq }
    public var serverDoc: Document? { server?.seqr.doc }
    public var committedLog: [LogEntry] { (server?.disk ?? serverDisk).log }

    // MARK: - Network

    private mutating func enqueue(_ payload: Packet.Payload, slot i: Int) {
        guard slots[i].linkUp else {
            rec.stats.bump("net.dropped.down")
            return
        }
        var ordered = false
        switch payload {
        case .event, .streamEnd: ordered = true
        default: break
        }
        if !ordered, !calm, rng.chance(cfg.dropRate) {
            rec.stats.bump("net.dropped.random")
            return
        }
        let copies = (!ordered && !calm && rng.chance(cfg.dupRate)) ? 2 : 1
        if copies == 2 { rec.stats.bump("net.duplicated") }
        for _ in 0..<copies {
            tie += 1
            var at = now + rng.int(1...max(1, cfg.maxDelay))
            if ordered {  // FIFO per connection
                at = max(at, slots[i].streamClock)
                slots[i].streamClock = at
            }
            packets.append(Packet(at: at, tie: tie, slot: i, slotEpoch: slots[i].epoch, serverEpoch: serverEpoch, payload: payload))
        }
    }

    private mutating func perform(_ requests: [ClientRequest], from i: Int) {
        for r in requests {
            if traceEnabled { traceLog.append("t=\(now) perform slot\(i) \(String(describing: r).prefix(110))") }
            switch r {
            case .submit(let req): enqueue(.post(req), slot: i)
            case .openStream(let o):
                connCounter += 1
                enqueue(.open(o, conn: connCounter), slot: i)
            }
        }
    }

    private mutating func sendEvents(_ events: [(to: ClientID, event: StreamEvent)], gen: [ClientID: Int]) {
        for (to, ev) in events {
            guard let j = slots.firstIndex(where: { $0.id == to }), let g = gen[to] else { continue }
            enqueue(.event(ev, generation: g), slot: j)
        }
    }

    public var packetsInFlight: Int { packets.count }

    // MARK: - Stepping

    /// Advances logical time by one tick: timers, deliveries, client timers, then random behaviour.
    public mutating func step() {
        now += 1
        rec.stats.bump("steps")
        runTimers()
        deliver(upTo: now)
        if now % cfg.pingEvery == 0, let s = server { sendEvents(s.pings(), gen: s.subs.mapValues(\.generation)) }
        tickClients()
        if !calm { randomActions() }
        if now % 10 == 0 { checkIntegrityOnline() }
    }

    private mutating func runTimers() {
        if let t = serverRestartAt, t <= now { restartServer() }
        for i in slots.indices {
            if let t = slots[i].restartAt, t <= now { restartClient(i) }
            if let t = slots[i].linkRestoreAt, t <= now { restoreLink(i) }
            if let t = slots[i].reconnectAt, t <= now, server != nil {
                slots[i].reconnectAt = nil
                networkAvailable(i)
            }
        }
    }

    private mutating func deliver(upTo t: Int) {
        let due = packets.filter { $0.at <= t }.sorted { ($0.at, $0.tie) < ($1.at, $1.tie) }
        packets.removeAll { $0.at <= t }
        for p in due { deliver(p) }
    }

    /// Delivers every in-flight packet now regardless of its delay (scripted tests). Replies are
    /// queued, not delivered, so callers can control interleavings.
    public mutating func flush(slot: Int? = nil, toServer: Bool? = nil) {
        let selected = packets.filter { p in
            (slot == nil || p.slot == slot!) && (toServer == nil || {
                switch p.payload {
                case .post, .open: return toServer!
                default: return !toServer!
                }
            }())
        }.sorted { ($0.at, $0.tie) < ($1.at, $1.tie) }
        let ids = Set(selected.map(\.tie))
        packets.removeAll { ids.contains($0.tie) }
        for p in selected { deliver(p) }
    }

    private mutating func deliver(_ p: Packet) {
        if traceEnabled { traceLog.append("t=\(now) deliver slot\(p.slot) \(p.slotEpoch == slots[p.slot].epoch && p.serverEpoch == serverEpoch ? "" : "DEAD ")\(String(describing: p.payload).prefix(110))") }
        guard p.slotEpoch == slots[p.slot].epoch, p.serverEpoch == serverEpoch else { return }
        switch p.payload {
        case .post(let req):
            guard server != nil else { return }
            if !calm && rng.chance(cfg.serverCrashRate * 0.5) {
                if rng.chance(0.5) {
                    rec.stats.bump("crash.server.beforeHandle")  // request lost, never logged
                    crashServer()
                } else {
                    _ = server!.submit(req)  // committed durably, reply and broadcast lost
                    rec.stats.bump("crash.server.afterCommitBeforeReply")
                    crashServer()
                }
                return
            }
            let out = server!.submit(req)
            if let r = out.response { enqueue(.response(r), slot: slotIndex(req.client)) }
            var gens = server!.subs.mapValues(\.generation)
            for (c, g) in out.closed { gens[c] = g }
            sendEvents(out.events, gen: gens)
            for (c, g) in out.closed {
                rec.stats.bump("sync.legacyStreamEnded")
                enqueue(.streamEnd(generation: g), slot: slotIndex(c))
            }

        case .open(let o, let conn):
            guard server != nil, let client = o.client else { return }
            let events = server!.open(o, conn: conn)
            if server!.subs[client]?.conn == conn {
                sendEvents(events.map { (client, $0) }, gen: [client: o.generation])
            }

        case .response(let r):
            guard slots[p.slot].client != nil else { return }
            let out = slots[p.slot].client!.receive(r, now: now)
            perform(out, from: p.slot)
            collect(p.slot)

        case .streamEnd(let g):
            guard slots[p.slot].client != nil else { return }
            slots[p.slot].client!.streamClosed(generation: g, now: now)

        case .event(let ev, let g):
            guard slots[p.slot].client != nil else { return }
            if case .snapshot = ev { rec.stats.bump("sync.snapshotJoin") }
            let out = slots[p.slot].client!.receive(ev, generation: g, now: now)
            perform(out, from: p.slot)
            collect(p.slot)
        }
    }

    private mutating func tickClients() {
        for i in slots.indices where slots[i].client != nil {
            let out = slots[i].client!.tick(now: now)
            perform(out, from: i)
            collect(i)
        }
    }

    // MARK: - Client events

    /// Drains a client's events into the record and lets the simulated user react.
    mutating func collect(_ i: Int) {
        guard slots[i].client != nil else { return }
        for ev in slots[i].client!.drainEvents() {
            let id = slots[i].id
            switch ev {
            case .committed(let cseq, let seq):
                rec.terminals[OpKey(client: id, cseq: cseq), default: []].append(.committed(seq: seq))
                rec.stats.bump("op.committed")
                if let m = slots[i].deleteMemo.removeValue(forKey: cseq) { restorable[m.node.id] = (m.node, m.edges, id) }
            case .rejected(let cseq, let op, let reason):
                slots[i].deleteMemo[cseq] = nil
                if case .restoreNode = op { rec.stats.bump("restore.rejected." + reason.name) }
                rec.terminals[OpKey(client: id, cseq: cseq), default: []].append(.rejected(reason))
                rec.stats.bump("op.rejected")
                rec.stats.bump("reject." + reason.name)
                if case .conflict = reason, !calm, rng.chance(cfg.reapplyRate) {
                    switch op {
                    case .setField, .updateItem: slots[i].reapplyQueue.append(op)
                    default: break
                    }
                }
            case .lost(let cseq):
                slots[i].deleteMemo[cseq] = nil
                rec.terminals[OpKey(client: id, cseq: cseq), default: []].append(.lost)
                rec.stats.bump("op.lost")
            case .conflictDetected:
                rec.stats.bump("notice.conflictDetectedEarly")
            case .localInvalid(_, let reason):
                rec.stats.bump("edit.localInvalid")
                rec.localRefusals.append((id, reason.name))
            }
        }
        if !slots[i].client!.violations.isEmpty {
            for v in slots[i].client!.violations where !rec.violations.contains("\(slots[i].id): \(v)") {
                rec.violations.append("\(slots[i].id): \(v)")
            }
        }
    }

    // MARK: - User actions (public for scripted scenarios)

    @discardableResult
    public mutating func userEdit(_ i: Int, _ op: Op, base requested: Int? = nil, sameValue: Bool = false) -> Int? {
        guard slots[i].client != nil else { return nil }
        let base = min(max(requested ?? slots[i].client!.lastSeq, 0), slots[i].client!.lastSeq)
        let r = slots[i].client!.edit(op, base: base, now: now)
        if let cseq = r.cseq {
            let key = OpKey(client: slots[i].id, cseq: cseq)
            rec.issued[key] = Issued(op: op, base: base)
            if sameValue { rec.sameValueOps.insert(key) }
            rec.stats.bump("op.issued")
        }
        perform(r.requests, from: i)
        collect(i)
        return r.cseq
    }

    public func slotIndex(_ id: ClientID) -> Int { slots.firstIndex { $0.id == id }! }

    /// First start of a client process: runs its first tick (which opens the stream).
    private mutating func boot(_ i: Int) {
        guard slots[i].client != nil, slots[i].linkUp else { return }
        let out = slots[i].client!.tick(now: now)
        perform(out, from: i)
    }

    /// "The network is back": the platform tells the client to reconnect right away.
    public mutating func networkAvailable(_ i: Int) {
        guard slots[i].client != nil, slots[i].linkUp else { return }
        let out = slots[i].client!.networkAvailable(now: now)
        perform(out, from: i)
    }

    /// Network partition / airplane mode: in-flight packets of this client die with the connection.
    public mutating func dropLink(_ i: Int, restoreAfter: Int? = nil) {
        guard slots[i].linkUp else { return }
        slots[i].linkUp = false
        slots[i].epoch += 1
        slots[i].streamClock = 0
        if let c = slots[i].client { slots[i].client!.streamClosed(generation: c.generation, now: now) }
        server?.subs[slots[i].id] = nil  // the TCP connection is gone; the server stops writing to it
        slots[i].linkRestoreAt = restoreAfter.map { now + $0 }
        rec.stats.bump("fault.linkDown")
    }

    public mutating func restoreLink(_ i: Int) {
        slots[i].linkRestoreAt = nil
        slots[i].linkUp = true
        networkAvailable(i)
    }

    /// Process/tab crash: all volatile client state is gone; only `durable` survives.
    public mutating func crashClient(_ i: Int, restartAfter: Int? = nil) {
        guard slots[i].client != nil else { return }
        collect(i)
        slots[i].durable = slots[i].client!.durable
        slots[i].client = nil
        slots[i].epoch += 1
        slots[i].streamClock = 0
        server?.subs[slots[i].id] = nil  // the process died, its sockets with it
        slots[i].restartAt = restartAfter.map { now + $0 }
        rec.stats.bump(slots[i].journaled ? "fault.clientCrash.journaled" : "fault.clientCrash.volatile")
    }

    public mutating func restartClient(_ i: Int) {
        slots[i].restartAt = nil
        guard slots[i].client == nil, let d = slots[i].durable else { return }
        slots[i].client = Client(restoring: d, journaled: slots[i].journaled, defects: cfg.defects, config: config(legacy: slots[i].legacy))
        boot(i)
    }

    public mutating func crashServer(restartAfter: Int? = nil) {
        guard let s = server else { return }
        preCrash = (s.seqr.doc, s.seqr.seq)
        serverDisk = s.disk
        if cfg.lossyDisk && !serverDisk.log.isEmpty {
            serverDisk.dropTail(rng.int(1...min(3, serverDisk.log.count)))
        }
        server = nil
        serverEpoch += 1
        serverRestartAt = now + (restartAfter ?? rng.int(1...8))
        for i in slots.indices {
            slots[i].streamClock = 0
            if let c = slots[i].client { slots[i].client!.streamClosed(generation: c.generation, now: now) }
        }
        rec.stats.bump("fault.serverCrash")
    }

    public mutating func restartServer() {
        serverRestartAt = nil
        guard server == nil else { return }
        guard let s = try? SimServer(disk: serverDisk, snapshotEvery: cfg.snapshotEvery, maxReplay: cfg.maxReplay, defects: cfg.defects) else {
            rec.violations.append("recovery: durable log is not replayable")
            return
        }
        if let pre = preCrash, pre.doc != s.seqr.doc || pre.seq != s.seqr.seq {
            rec.violations.append("recovery: state after restart (seq \(s.seqr.seq)) != state before crash (seq \(pre.seq))")
        }
        preCrash = nil
        server = s
        for i in slots.indices where slots[i].linkUp && slots[i].client != nil {
            slots[i].reconnectAt = now + (calm ? 0 : rng.int(1...6))
        }
    }

    // MARK: - Random behaviour

    private mutating func randomActions() {
        if rng.chance(cfg.editRate) {
            let n = rng.chance(cfg.burstRate) ? rng.int(2...5) : 1
            if let i = rng.pick(slots.indices.filter { slots[$0].client?.hasState == true }) {
                for _ in 0..<n {
                    if let (op, same) = genOp(i) {
                        // A typing draft keeps the version it started from: sometimes the base is older than the client's head
                        // (and then not monotone across this client's ops).
                        let last = slots[i].client!.lastSeq
                        let base = rng.chance(0.2) ? max(0, last - rng.int(1...10)) : nil
                        var memo: (node: Node, edges: [Edge])?
                        if case .removeNode(let id) = op, let n = slots[i].client!.view.nodes[id] {
                            memo = (n, slots[i].client!.view.edges.values.filter { $0.source == id || $0.target == id }
                                .sorted { $0.id < $1.id })
                        }
                        let cseq = userEdit(i, op, base: base, sameValue: same)
                        if case .restoreNode = op { rec.stats.bump(cseq == nil ? "restore.refusedLocally" : "restore.issued") }
                        if let cseq, let memo { slots[i].deleteMemo[cseq] = memo }
                    }
                }
            }
        }
        if let i = rng.pick(slots.indices.filter { !slots[$0].reapplyQueue.isEmpty && slots[$0].client != nil }) {
            userEdit(i, slots[i].reapplyQueue.removeFirst())
            rec.stats.bump("user.reapplied")
        }
        if rng.chance(cfg.disconnectRate), let i = rng.pick(slots.indices.filter { slots[$0].linkUp }) {
            let long = rng.chance(cfg.longOfflineRate)
            dropLink(i, restoreAfter: long ? rng.int(60...200) : rng.int(2...15))
            if long { rec.stats.bump("fault.longOffline") }
        }
        if rng.chance(cfg.clientCrashRate), let i = rng.pick(slots.indices.filter { slots[$0].client != nil }) {
            crashClient(i, restartAfter: rng.int(1...10))
        }
        if rng.chance(cfg.serverCrashRate), server != nil {
            crashServer()
        }
    }

    // MARK: - Edit generator

    private static let fieldPool: [[String]] = [
        ["prompt"], ["model"], ["model", "name"], ["model", "temp"], ["code"], ["vars", "a"], ["inputs"],
    ]
    static let listPath = ["outs"]

    private mutating func genOp(_ i: Int) -> (Op, Bool)? {
        let view = slots[i].client!.view
        let ids = view.nodes.keys.sorted()
        // Undo of a delete (protocol 1.6): the user's own. Sometimes a user tries to undo someone else's delete, which
        // the protocol refuses (`notDeleter`, already by the local pre-check).
        if !slots[i].legacy, rng.chance(cfg.restoreRate) {
            let gone = restorable.keys.sorted().filter { view.nodes[$0] == nil && view.deletedNodes[$0] != nil }
            let own = gone.filter { restorable[$0]!.by == slots[i].id }
            if let id = rng.pick(rng.chance(0.1) ? gone : own) {
                return (.restoreNode(restorable[id]!.node, edges: restorable[id]!.edges), false)
            }
        }
        if ids.count < 3 { return (newNodeOp(ids), false) }
        let roll = rng.int(0...99)
        let node = rng.pick(ids)!
        func items(_ n: NodeID) -> [Item] {
            if case .items(let xs)? = view.nodes[n]?.config[Self.listPath[0]] { return xs }
            return []
        }
        switch roll {
        case 0..<24:
            let path = rng.pick(Self.fieldPool)!
            return (.setField(node, .config(path), genValue(path, ids)), false)
        case 24..<30: return (.setField(node, .title, .string("t\(rng.int(0...999))")), false)
        case 30..<40: return (.moveNode(node, x: rng.int(0...800), y: rng.int(0...800)), false)
        case 40..<46: return (newNodeOp(ids), false)
        case 46..<51: return (.removeNode(node), false)
        case 51..<60:
            guard let other = rng.pick(ids) else { return nil }
            edgeCounter += 1
            return (.addEdge(Edge(id: "e\(edgeCounter)", source: node, sourceHandle: rng.chance(0.5) ? "out" : "alt",
                                  target: other, targetHandle: "in")), false)
        case 60..<65:
            guard let e = rng.pick(view.edges.keys.sorted()) else { return nil }
            return (.removeEdge(e), false)
        case 65..<70:
            let target = rng.pick(ids)!
            return (.setField(node, .config(["inputs"]), .list([.ref(OutputRef(node: target, output: "out"))])), false)
        case 70..<78:
            // Same-value writes: a few hot registers that only ever receive one constant.
            let j = rng.int(0...2)
            return (.setField(node, .config(["hot", "k\(j)"]), .string("HOT\(j)")), true)
        case 78..<88:
            let xs = items(node)
            itemCounter += 1
            let after = xs.isEmpty || rng.chance(0.3) ? nil : rng.pick(xs)!.id
            return (.insertItem(node, path: Self.listPath, item: Item(id: "i\(itemCounter)", value: .string("it\(itemCounter)")), after: after), false)
        case 88..<93:
            guard let it = rng.pick(items(node)) else { return nil }
            return (.removeItem(node, path: Self.listPath, id: it.id), false)
        case 93..<98:
            guard let it = rng.pick(items(node)) else { return nil }
            return (.updateItem(node, path: Self.listPath, id: it.id, value: .string("u\(rng.int(0...99))")), false)
        default:
            itemCounter += 1
            let fresh = (0..<rng.int(0...3)).map { k in Item(id: "i\(itemCounter)_\(k)", value: .int(k)) }
            return (.setField(node, .config(Self.listPath), .items(fresh)), false)
        }
    }

    private mutating func newNodeOp(_ ids: [NodeID]) -> Op {
        nodeCounter += 1
        var cfg: [String: Value] = ["prompt": .string("p")]
        if let t = rng.pick(ids), rng.chance(0.4) { cfg["ref"] = .ref(OutputRef(node: t, output: "out")) }
        return .addNode(Node(id: "n\(nodeCounter)", type: "llm", title: "N\(nodeCounter)",
                             x: rng.int(0...800), y: rng.int(0...800), config: cfg))
    }

    private mutating func genValue(_ path: [String], _ ids: [NodeID]) -> Value {
        switch rng.int(0...9) {
        case 0: return .int(rng.int(0...100))
        case 1 where path == ["model"]: return .map(["name": .string("m\(rng.int(0...9))")])
        case 2: return .ref(OutputRef(node: rng.pick(ids)!, output: "out"))
        // Few distinct values so that stale same-value writes happen naturally too.
        case 3, 4: return .string("v\(rng.int(0...2))")
        default: return .string("v\(rng.int(0...9999))")
        }
    }

    // MARK: - Quiescence

    /// Heals all faults, stops user activity, and runs until every client has converged.
    /// Returns false if the system failed to settle within `maxSteps` (itself a violation).
    @discardableResult
    public mutating func settle(maxSteps: Int = 5000) -> Bool {
        calm = true
        for i in slots.indices { slots[i].reapplyQueue = [] }
        if server == nil { restartServer() }
        for i in slots.indices {
            if slots[i].client == nil { restartClient(i) }
            if !slots[i].linkUp { restoreLink(i) }
            slots[i].reconnectAt = nil
        }
        var stable = 0
        for _ in 0..<maxSteps {
            step()
            if isConverged { stable += 1 } else { stable = 0 }
            if stable >= 3 * cfg.maxDelay + 20 { return true }
        }
        return false
    }

    public var isConverged: Bool {
        guard let s = server else { return false }
        return slots.allSatisfy { $0.client?.isQuiescent == true && $0.client?.lastSeq == s.seqr.seq }
    }

    private mutating func violate(_ message: String) {
        if rec.violations.count < 40 && !rec.violations.contains(message) { rec.violations.append(message) }
    }

    private mutating func checkIntegrityOnline() {
        if let s = server {
            for p in s.seqr.doc.integrityProblems { violate("I4 server: \(p)") }
        }
        for sl in slots {
            guard let c = sl.client else { continue }
            for p in c.view.integrityProblems { violate("I4 \(sl.id) view: \(p)") }
        }
    }

    public var debugNet: String {
        let up = server == nil ? "down" : "up"
        let subs = server.map { String(describing: $0.subs.mapValues { "conn\($0.conn)/gen\($0.generation)" }) } ?? "-"
        return "now=\(now) server=\(up) subs=\(subs) inflight=\(packets.count) links=\(slots.map(\.linkUp))"
    }

    // MARK: - Evidence

    public func evidence() -> Evidence? {
        guard let s = server else { return nil }
        let clients = slots.map { sl in
            ClientEvidence(id: sl.id, confirmed: sl.client?.confirmed, view: sl.client?.view, unresolved: sl.client?.unresolvedCount ?? 0)
        }
        var pre = rec.violations
        if s.disk.log.count != s.seqr.seq { pre.append("LOG: server.seq \(s.seqr.seq) != log length \(s.disk.log.count)") }
        return Evidence(initial: rec.initial, log: s.disk.log, serverDoc: s.seqr.doc, clients: clients, issued: rec.issued,
                        terminals: rec.terminals, sameValueOps: rec.sameValueOps, priorViolations: pre)
    }
}

// MARK: - Scripted-scenario helpers

extension World {
    /// Delivers packets (and the replies they trigger) until the network is empty. Scripted use only.
    public mutating func drain(maxRounds: Int = 100) {
        var rounds = 0
        while packetsInFlight > 0 && rounds < maxRounds {
            flush()
            rounds += 1
        }
    }

    public func terminals(_ client: ClientID, _ cseq: Int) -> [Terminal] {
        rec.terminals[OpKey(client: client, cseq: cseq)] ?? []
    }

    public func serverField(_ node: NodeID, _ key: String) -> Value? {
        server?.seqr.doc.nodes[node]?.config[key]
    }
}
