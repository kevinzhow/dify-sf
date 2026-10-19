// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0):
// graphon/graph_engine/filters/response_stream.py (ResponseStreamFilter, as Dify 1.17.1 applies it in
// `iter_dify_graph_engine_events`). See ../NOTICE.md.
//
// Not ported: `dumps` / `loads` (pause and resume, P4).

import Foundation

/// Dify's ordered response streaming: response nodes (answer, end) stream their templates in order, one session at a
/// time; a node's text chunks are buffered until the session reaches the selector; a session starts once every blocking
/// edge on some path from the root to its node was taken. Chunks no template references are dropped; edge events are
/// consumed.
struct ResponseStreamFilter {
    struct State {
        var pool: VariablePool
        var nodeStates: [String: NodeState]
    }

    struct Session {
        var nodeId: String
        var template: ResponseTemplate
        var index = 0
        var isComplete: Bool { index >= template.segments.count }
    }

    struct Chunk {
        var executionId: String
        var nodeId: String
        var selector: [String]
        var chunk: String
        var isFinal: Bool
    }

    let graph: RuntimeGraph
    var activeSession: Session?
    var waitingSessions: [Session] = []
    var responseSessions: [String: Session] = [:]
    var responseNodes: [String] = []
    var pathsMaps: [String: [[String]]] = [:]
    var nodeExecutionIds: [String: String] = [:]
    var referencedSelectors = Set<[String]>()
    var buffers: [[String]: [Chunk]] = [:]
    var positions: [[String]: Int] = [:]
    var closed = Set<[String]>()

    init(graph: RuntimeGraph) {
        self.graph = graph
        for id in graph.nodeIds where graph.executionType(id) == .response { register(id) }
        responseNodes.sort()
    }

    mutating func register(_ nodeId: String) {
        guard let template = graph.nodes[nodeId]?.streamingTemplate else { return }
        responseNodes.append(nodeId)
        pathsMaps[nodeId] = buildPathsMap(nodeId, template)
        responseSessions[nodeId] = Session(nodeId: nodeId, template: template)
        for case .variable(let sel) in template.segments { referencedSelectors.insert(sel) }
    }

    func buildPathsMap(_ responseNodeId: String, _ template: ResponseTemplate) -> [[String]] {
        if graph.rootId == responseNodeId { return [[]] }
        var selectors = Set<[String]>()
        for case .variable(let sel) in template.segments { selectors.insert(Array(sel.prefix(2))) }
        var paths: [[String]] = []
        func walk(_ current: String, _ path: [String], _ visited: Set<String>) {
            if current == responseNodeId { paths.append(path); return }
            var next = visited
            next.insert(current)
            for e in graph.outgoing(current) where !next.contains(e.head) {
                walk(e.head, path + [e.id], next)
            }
        }
        walk(graph.rootId, [], [])
        return paths.map { path in
            path.filter { id in
                guard let e = graph.edges[id], let source = graph.nodes[e.tail] else { return false }
                switch graph.executionType(e.tail) {
                case .branch, .container, .response: return true
                default: return source.blocksVariableOutput(selectors)
                }
            }
        }
    }

    mutating func onEvent(_ event: GraphEngineEvent, state: State) -> [GraphEngineEvent] {
        switch event {
        case .runStarted:
            return [event] + activateInitialSessions(state)
        case .node(let e):
            switch e {
            case .started(let x, let nodeId, _, _, _):
                nodeExecutionIds[nodeId] = x
                return [event]
            case .streamChunk(let x, let nodeId, let selector, let chunk, let isFinal):
                guard referencedSelectors.contains(selector) else { return [] }
                if closed.contains(selector) { return [] }  // graphon raises "Stream ... is already closed"
                if buffers[selector] == nil { buffers[selector] = []; positions[selector] = 0 }
                buffers[selector]!.append(Chunk(executionId: x, nodeId: nodeId, selector: selector, chunk: chunk, isFinal: isFinal))
                if isFinal { closed.insert(selector) }
                return tryFlush(state)
            case .reasoningChunk(_, let nodeId, let selector, _, _):
                return isReasoningVisible(nodeId: nodeId, selector: selector, state: state) ? [event] : []
            case .succeeded, .exception:
                return tryFlush(state) + [event]
            default:
                return [event]
            }
        case .edgeTaken(let edge):
            return handleEdgeTaken(edge.id, state)
        case .edgeSkipped:
            return []
        default:
            return [event]
        }
    }

    mutating func flush(state: State) -> [GraphEngineEvent] { tryFlush(state) }

    // MARK: Sessions

    mutating func activateInitialSessions(_ state: State) -> [GraphEngineEvent] {
        var events: [GraphEngineEvent] = []
        for id in responseNodes where (pathsMaps[id] ?? []).contains(where: \.isEmpty) {
            events += activeOrQueueSession(id, state)
        }
        return events
    }

    mutating func handleEdgeTaken(_ edgeId: String, _ state: State) -> [GraphEngineEvent] {
        var events: [GraphEngineEvent] = []
        for id in responseNodes {
            guard var paths = pathsMaps[id] else { continue }
            var reachable = false
            for i in paths.indices {
                paths[i].removeAll { $0 == edgeId }
                if paths[i].isEmpty { reachable = true }
            }
            pathsMaps[id] = paths
            if reachable { events += activeOrQueueSession(id, state) }
        }
        return events
    }

    mutating func activeOrQueueSession(_ nodeId: String, _ state: State) -> [GraphEngineEvent] {
        guard let session = responseSessions.removeValue(forKey: nodeId) else { return [] }
        if activeSession == nil {
            activeSession = session
            return tryFlush(state)
        }
        waitingSessions.append(session)
        return []
    }

    mutating func tryFlush(_ state: State) -> [GraphEngineEvent] {
        guard var session = activeSession else { return [] }
        var events: [GraphEngineEvent] = []
        while session.index < session.template.segments.count {
            switch session.template.segments[session.index] {
            case .variable(let selector):
                if let first = selector.first, graph.nodes[first] != nil, state.nodeStates[first] == .skipped {
                    session.index += 1
                    continue
                }
                activeSession = session
                let (out, complete) = processVariableSegment(selector, state)
                events += out
                if complete { session.index += 1 } else {
                    activeSession = session
                    return events
                }
            case .text(let text):
                let responseNode = session.nodeId
                let executionId = executionId(of: responseNode)
                let isLast = session.index == session.template.segments.count - 1
                let selector = graph.nodes[responseNode]?.streamingTextSelector ?? [responseNode, "answer"]
                events.append(.node(.streamChunk(executionId: executionId, nodeId: responseNode, selector: selector, chunk: text,
                                                 isFinal: isLast)))
                session.index += 1
            }
        }
        activeSession = session
        if session.isComplete { events += endSession(session.nodeId, state) }
        return events
    }

    mutating func endSession(_ nodeId: String, _ state: State) -> [GraphEngineEvent] {
        guard activeSession?.nodeId == nodeId else { return [] }
        activeSession = nil
        guard !waitingSessions.isEmpty else { return [] }
        activeSession = waitingSessions.removeFirst()
        return tryFlush(state)
    }

    mutating func executionId(of nodeId: String) -> String {
        if let x = nodeExecutionIds[nodeId] { return x }
        let x = UUID().uuidString.lowercased()
        nodeExecutionIds[nodeId] = x
        return x
    }

    /// `_process_variable_segment`: the buffered chunks of the selector, else (no stream for it) its value once in the pool.
    mutating func processVariableSegment(_ selector: [String], _ state: State) -> ([GraphEngineEvent], Bool) {
        var events: [GraphEngineEvent] = []
        let prefix = selector.first ?? ""
        let isSpecial = graph.nodes[prefix] == nil
        let outputNode = (activeSession != nil && isSpecial) ? activeSession!.nodeId : prefix
        let executionId = executionId(of: outputNode)
        let hasStreamEvents = buffers[selector] != nil
        while let buffer = buffers[selector], let pos = positions[selector], pos < buffer.count {
            let c = buffer[pos]
            positions[selector] = pos + 1
            if let session = activeSession, isSpecial {
                events.append(.node(.streamChunk(executionId: executionId, nodeId: session.nodeId, selector: c.selector, chunk: c.chunk,
                                                 isFinal: c.isFinal)))
            } else {
                events.append(.node(.streamChunk(executionId: c.executionId, nodeId: c.nodeId, selector: c.selector, chunk: c.chunk,
                                                 isFinal: c.isFinal)))
            }
        }
        if closed.contains(selector) { return (events, true) }
        if !hasStreamEvents, let value = state.pool.get(selector) {
            let isLast = activeSession.map { $0.index == $0.template.segments.count - 1 } ?? false
            let node = isSpecial ? (activeSession?.nodeId ?? outputNode) : outputNode
            events.append(.node(.streamChunk(executionId: executionId, nodeId: node, selector: selector, chunk: value.markdown, isFinal: isLast)))
            return (events, true)
        }
        return (events, false)
    }

    // MARK: Reasoning

    func isReasoningVisible(nodeId: String, selector: [String], state: State) -> Bool {
        guard selector == [nodeId, "reasoning_content"], graph.nodes[nodeId] != nil, state.nodeStates[nodeId] != .skipped else { return false }
        let prefixes: Set<[String]> = [selector, [nodeId, "text"]]
        var sessions: [Session] = []
        if let a = activeSession { sessions.append(a) }
        sessions += waitingSessions
        return sessions.contains { s in
            s.template.segments.contains { seg in
                if case .variable(let sel) = seg { return prefixes.contains(Array(sel.prefix(2))) }
                return false
            }
        }
    }
}
