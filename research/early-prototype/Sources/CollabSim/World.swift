import CollabCore

public struct OpKey: Hashable, Sendable {
    public var client: ClientID
    public var cseq: Int
}

public struct Issued: Sendable {
    public var op: Op
    public var base: Int
}

/// Terminal outcome as the *user would have seen it* (taken from client events, not server state).
public enum Terminal: Hashable, Sendable {
    case committed(seq: Int)
    case rejected(String)
    case lost
}

public struct Stats: Sendable {
    public private(set) var counters: [String: Int] = [:]
    public init() {}
    mutating func bump(_ key: String, _ n: Int = 1) { counters[key, default: 0] += n }
    public subscript(key: String) -> Int { counters[key] ?? 0 }
    public mutating func merge(_ other: Stats) {
        for (k, v) in other.counters { counters[k, default: 0] += v }
    }
}

/// Everything the invariant checker needs that the protocol itself does not retain.
public struct Record: Sendable {
    public var initial: Document
    public var issued: [OpKey: Issued] = [:]
    public var terminals: [OpKey: [Terminal]] = [:]
    public var violations: [String] = []
    public var stats = Stats()
}

struct Packet: Sendable {
    enum Payload: Sendable {
        case toServer(ClientMessage)
        case toClient(ServerMessage)
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
    public var client: Client?
    var durable: ClientDurable?
    public var linkUp = true
    var epoch = 0
    var restartAt: Int?
    var linkRestoreAt: Int?
    var connectAt: Int?
    var reapplyQueue: [Op] = []
}

/// One simulated deployment: a server, N clients, a lossy reordering network and a fault injector.
/// Entirely deterministic given (config, seed). Scenario tests drive it by hand through the public
/// methods; the fuzzer drives it with `step()`.
public struct World: Sendable {
    public let cfg: SimConfig
    public private(set) var rng: Rng
    public private(set) var now = 0
    public private(set) var server: Server?
    public private(set) var serverDisk: Disk
    public private(set) var slots: [Slot] = []
    public var rec: Record

    private var packets: [Packet] = []
    private var tie = 0
    private var serverEpoch = 0
    private var serverRestartAt: Int?
    private var preCrash: (doc: Document, seq: Int)?
    private var calm = false
    private var nodeCounter = 0
    private var edgeCounter = 0

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
        serverDisk = Disk(initial: doc)
        server = Server(disk: serverDisk, snapshotEvery: cfg.snapshotEvery, defects: cfg.defects)
        nodeCounter = cfg.initialNodes
        let ids = clientIDs ?? (0..<cfg.clientCount).map { "c\($0)" }
        for id in ids {
            let journaled = !rng.chance(cfg.volatileFraction)
            slots.append(Slot(id: id, journaled: journaled,
                              client: Client(id: id, journaled: journaled, defects: cfg.defects)))
        }
        self.rng = rng
        for i in slots.indices { connect(i) }
    }

    // MARK: - Network

    private mutating func enqueue(_ payload: Packet.Payload, slot i: Int) {
        guard slots[i].linkUp else {
            rec.stats.bump("net.dropped.down")
            return
        }
        if !calm && rng.chance(cfg.dropRate) {
            rec.stats.bump("net.dropped.random")
            return
        }
        let copies = (!calm && rng.chance(cfg.dupRate)) ? 2 : 1
        if copies == 2 { rec.stats.bump("net.duplicated") }
        for _ in 0..<copies {
            tie += 1
            packets.append(Packet(at: now + rng.int(1...max(1, cfg.maxDelay)), tie: tie, slot: i,
                                  slotEpoch: slots[i].epoch, serverEpoch: serverEpoch, payload: payload))
        }
    }

    private mutating func send(_ msgs: [ClientMessage], from i: Int) {
        for m in msgs { enqueue(.toServer(m), slot: i) }
    }

    public var packetsInFlight: Int { packets.count }

    // MARK: - Stepping

    /// Advances logical time by one tick: timers, deliveries, client timers, then random behaviour.
    public mutating func step() {
        now += 1
        rec.stats.bump("steps")
        runTimers()
        deliver(upTo: now)
        tickClients()
        if !calm { randomActions() }
        if now % 10 == 0 { checkIntegrityOnline() }
    }

    private mutating func runTimers() {
        if let t = serverRestartAt, t <= now { restartServer() }
        for i in slots.indices {
            if let t = slots[i].restartAt, t <= now { restartClient(i) }
            if let t = slots[i].linkRestoreAt, t <= now { restoreLink(i) }
            if let t = slots[i].connectAt, t <= now, server != nil {
                slots[i].connectAt = nil
                if slots[i].client != nil && slots[i].linkUp { connect(i) }
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
                if case .toServer = p.payload { return toServer! }
                return !toServer!
            }())
        }.sorted { ($0.at, $0.tie) < ($1.at, $1.tie) }
        let ids = Set(selected.map(\.tie))
        packets.removeAll { ids.contains($0.tie) }
        for p in selected { deliver(p) }
    }

    private mutating func deliver(_ p: Packet) {
        guard p.slotEpoch == slots[p.slot].epoch, p.serverEpoch == serverEpoch else { return }
        switch p.payload {
        case .toServer(let msg):
            guard server != nil else { return }
            if !calm && rng.chance(cfg.serverCrashRate * 0.5) {
                if rng.chance(0.5) {
                    rec.stats.bump("crash.server.beforeHandle")  // message lost, never logged
                    crashServer()
                } else {
                    _ = server!.handle(msg)  // logged (acked-to-nobody), reply lost
                    rec.stats.bump("crash.server.afterLogBeforeSend")
                    crashServer()
                }
                return
            }
            let out = server!.handle(msg)
            for o in out {
                guard let j = slots.firstIndex(where: { $0.id == o.to }) else { continue }
                enqueue(.toClient(o.message), slot: j)
            }
        case .toClient(let msg):
            guard slots[p.slot].client != nil else { return }
            if case .welcome(let w) = msg, w.snapshot != nil { rec.stats.bump("sync.snapshotJoin") }
            let out = slots[p.slot].client!.receive(msg, now: now)
            send(out, from: p.slot)
            collect(p.slot)
        }
    }

    private mutating func tickClients() {
        for i in slots.indices where slots[i].client != nil {
            let out = slots[i].client!.tick(now: now)
            send(out, from: i)
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
            case .rejected(let cseq, let op, let reason):
                rec.terminals[OpKey(client: id, cseq: cseq), default: []].append(.rejected("\(reason)"))
                rec.stats.bump("op.rejected")
                rec.stats.bump("reject." + Self.reasonName(reason))
                if case .conflict = reason, !calm, rng.chance(cfg.reapplyRate) {
                    switch op {
                    case .setField, .moveNode: slots[i].reapplyQueue.append(op)
                    default: break
                    }
                }
            case .lost(let cseq):
                rec.terminals[OpKey(client: id, cseq: cseq), default: []].append(.lost)
                rec.stats.bump("op.lost")
            case .conflictDetected:
                rec.stats.bump("notice.conflictDetectedEarly")
            case .localInvalid:
                rec.stats.bump("edit.localInvalid")
            }
        }
        if !slots[i].client!.violations.isEmpty {
            for v in slots[i].client!.violations where !rec.violations.contains("\(slots[i].id): \(v)") {
                rec.violations.append("\(slots[i].id): \(v)")
            }
        }
    }

    static func reasonName(_ r: RejectReason) -> String {
        switch r {
        case .conflict: return "conflict"
        case .nodeDeleted: return "nodeDeleted"
        case .nodeNotFound: return "nodeNotFound"
        case .nodeExists: return "nodeExists"
        case .edgeNotFound: return "edgeNotFound"
        case .edgeExists: return "edgeExists"
        case .duplicateEdge: return "duplicateEdge"
        case .danglingReference: return "danglingReference"
        case .invalid: return "invalid"
        case .notCommitted: return "notCommitted"
        }
    }

    // MARK: - User actions (public for scripted scenarios)

    @discardableResult
    public mutating func userEdit(_ i: Int, _ op: Op) -> Int? {
        guard slots[i].client != nil else { return nil }
        let base = slots[i].client!.lastSeq
        let r = slots[i].client!.edit(op, now: now)
        if let cseq = r.cseq {
            rec.issued[OpKey(client: slots[i].id, cseq: cseq)] = Issued(op: op, base: base)
            rec.stats.bump("op.issued")
        }
        send(r.messages, from: i)
        collect(i)
        return r.cseq
    }

    public func slotIndex(_ id: ClientID) -> Int { slots.firstIndex { $0.id == id }! }

    public mutating func connect(_ i: Int) {
        guard slots[i].client != nil, slots[i].linkUp else { return }
        let out = slots[i].client!.connect(now: now)
        send(out, from: i)
    }

    /// Network partition / airplane mode: in-flight packets of this client die with the connection.
    public mutating func dropLink(_ i: Int, restoreAfter: Int? = nil) {
        guard slots[i].linkUp else { return }
        slots[i].linkUp = false
        slots[i].epoch += 1
        slots[i].client?.connectionLost()
        slots[i].linkRestoreAt = restoreAfter.map { now + $0 }
        rec.stats.bump("fault.linkDown")
    }

    public mutating func restoreLink(_ i: Int) {
        slots[i].linkRestoreAt = nil
        slots[i].linkUp = true
        if slots[i].client != nil { connect(i) }
    }

    /// Process/tab crash: all volatile client state is gone; only `durable` survives.
    public mutating func crashClient(_ i: Int, restartAfter: Int? = nil) {
        guard slots[i].client != nil else { return }
        collect(i)
        slots[i].durable = slots[i].client!.durable
        slots[i].client = nil
        slots[i].epoch += 1
        slots[i].restartAt = restartAfter.map { now + $0 }
        rec.stats.bump(slots[i].journaled ? "fault.clientCrash.journaled" : "fault.clientCrash.volatile")
    }

    public mutating func restartClient(_ i: Int) {
        slots[i].restartAt = nil
        guard slots[i].client == nil, let d = slots[i].durable else { return }
        slots[i].client = Client(restoring: d, journaled: slots[i].journaled, defects: cfg.defects)
        connect(i)
    }

    public mutating func crashServer(restartAfter: Int? = nil) {
        guard let s = server else { return }
        preCrash = (s.doc, s.seq)
        var disk = s.disk
        if cfg.lossyDisk && !disk.tail.isEmpty {
            disk.tail.removeLast(rng.int(1...min(3, disk.tail.count)))
        }
        serverDisk = disk
        server = nil
        serverEpoch += 1
        serverRestartAt = now + (restartAfter ?? rng.int(1...8))
        for i in slots.indices { slots[i].client?.connectionLost() }
        rec.stats.bump("fault.serverCrash")
    }

    public mutating func restartServer() {
        serverRestartAt = nil
        guard server == nil else { return }
        let s = Server(disk: serverDisk, snapshotEvery: cfg.snapshotEvery, defects: cfg.defects)
        if let pre = preCrash, pre.doc != s.doc || pre.seq != s.seq {
            rec.violations.append("recovery: state after restart (seq \(s.seq)) != state before crash (seq \(pre.seq))")
        }
        preCrash = nil
        server = s
        for i in slots.indices where slots[i].linkUp && slots[i].client != nil {
            slots[i].connectAt = now + (calm ? 0 : rng.int(1...6))
        }
    }

    // MARK: - Random behaviour

    private mutating func randomActions() {
        if rng.chance(cfg.editRate) {
            let n = rng.chance(cfg.burstRate) ? rng.int(2...5) : 1
            if let i = rng.pick(slots.indices.filter { slots[$0].client?.hasState == true }) {
                for _ in 0..<n { if let op = genOp(i) { userEdit(i, op) } }
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

    private mutating func genOp(_ i: Int) -> Op? {
        let view = slots[i].client!.view
        let ids = view.nodes.keys.sorted()
        if ids.count < 3 { return newNodeOp(ids) }
        let roll = rng.int(0...99)
        let node = rng.pick(ids)!
        switch roll {
        case 0..<34:
            let path = rng.pick(Self.fieldPool)!
            return .setField(node, .config(path), genValue(path, ids))
        case 34..<42: return .setField(node, .title, .string("t\(rng.int(0...999))"))
        case 42..<54: return .moveNode(node, x: rng.int(0...800), y: rng.int(0...800))
        case 54..<62: return newNodeOp(ids)
        case 62..<68: return .removeNode(node)
        case 68..<80:
            guard let other = rng.pick(ids) else { return nil }
            edgeCounter += 1
            return .addEdge(Edge(id: "e\(edgeCounter)", source: node, sourceHandle: rng.chance(0.5) ? "out" : "alt",
                                 target: other, targetHandle: "in"))
        case 80..<86:
            guard let e = rng.pick(view.edges.keys.sorted()) else { return nil }
            return .removeEdge(e)
        default:
            let target = rng.pick(ids)!
            return .setField(node, .config(["inputs"]), .list([.ref(OutputRef(node: target, output: "out"))]))
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
            slots[i].connectAt = nil
            if slots[i].client != nil && !slots[i].client!.connected { connect(i) }
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
        return slots.allSatisfy { $0.client?.isQuiescent == true && $0.client?.lastSeq == s.seq }
    }

    private mutating func violate(_ message: String) {
        if rec.violations.count < 40 && !rec.violations.contains(message) { rec.violations.append(message) }
    }

    private mutating func checkIntegrityOnline() {
        if let s = server {
            for p in s.doc.integrityProblems { violate("I4 server: \(p)") }
        }
        for sl in slots {
            guard let c = sl.client else { continue }
            for p in c.view.integrityProblems { violate("I4 \(sl.id) view: \(p)") }
        }
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
        server?.doc.nodes[node]?.config[key]
    }
}
