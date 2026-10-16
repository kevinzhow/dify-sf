/// Document state at a sequence number: the unit of durable checkpointing.
public struct Snapshot: Hashable, Sendable {
    public var seq: Int
    public var doc: Document
    public init(seq: Int, doc: Document) {
        self.seq = seq
        self.doc = doc
    }
}

/// What processing one client batch decided. Nothing in here has happened durably yet: the caller must
/// persist `entries`, `rejections` and `newHigh` in ONE atomic commit before telling anyone.
public struct SequencerBatch: Sendable {
    public var response: SubmitResponse
    public var entries: [LogEntry]
    /// New rejections to remember durably (so a retransmit gets the original reason).
    public var rejections: [Int: RejectReason]
    public var newHigh: Int
    public var highChanged: Bool
    /// True when there is nothing to persist (pure duplicates / gaps / empty request).
    public var isEmpty: Bool { entries.isEmpty && rejections.isEmpty && !highChanged }
}

public enum RecoveryError: Error, Equatable, Sendable {
    case logGap(expected: Int, found: Int)
}

/// The per-document sequencer as a pure state machine. The server owns exactly one per document and
/// feeds it one request at a time (an actor in the real server, a plain call in the simulator).
///
/// Commit protocol: `process` works on this value; the caller applies it to a *copy*, persists the batch
/// atomically, and only then adopts the copy and answers the client. A failed or in-doubt persist
/// discards the copy and rebuilds from durable state (`init(snapshot:tail:)`).
public struct Sequencer: Sendable {
    public private(set) var doc: Document
    public private(set) var seq: Int
    public let defects: ProtocolDefects

    public init(initial: Document, defects: ProtocolDefects = []) {
        doc = initial
        seq = 0
        self.defects = defects
    }

    /// Crash recovery: latest snapshot + replay of the log entries after it.
    public init(snapshot: Snapshot, tail: [LogEntry], defects: ProtocolDefects = []) throws(RecoveryError) {
        doc = snapshot.doc
        seq = snapshot.seq
        self.defects = defects
        for e in tail where e.seq > snapshot.seq {
            guard e.seq == seq + 1 else { throw .logGap(expected: seq + 1, found: e.seq) }
            doc.apply(e.op, at: e.stamp, defects: defects)
            seq = e.seq
        }
    }

    public var snapshot: Snapshot { Snapshot(seq: seq, doc: doc) }

    /// The cseq range whose durable outcomes `process` needs as `known` (committed seq / rejection reason).
    public static func lookupRange(for req: SubmitRequest, clientHigh: Int) -> ClosedRange<Int>? {
        let effectiveHigh = max(clientHigh, (req.floor ?? 1) - 1)
        var lo = Int.max
        for op in req.ops where op.cseq <= effectiveHigh { lo = min(lo, op.cseq) }
        if let r = req.resolveFrom { lo = min(lo, max(1, r)) }
        guard lo <= effectiveHigh, lo >= 1 else { return nil }
        return lo...effectiveHigh
    }

    /// Validates, sequences and applies a batch from one client, in order.
    /// - Parameters:
    ///   - clientHigh: the durable high-water mark of this client (0 if never seen).
    ///   - known: durable outcomes for the range given by `lookupRange`.
    public mutating func process(_ req: SubmitRequest, clientHigh: Int, known: KnownOutcomes) -> SequencerBatch {
        var high = clientHigh
        var highChanged = false
        if let f = req.floor, f - 1 > high {
            high = f - 1
            highChanged = true
        }
        var results: [OpResult] = []
        var entries: [LogEntry] = []
        var rejections: [Int: RejectReason] = [:]
        var merged = known

        for inc in req.ops {
            let cseq = inc.cseq
            if cseq <= high && !defects.contains(.noDedup) {
                // Retransmit of something already handled: answer from durable facts, never apply twice.
                if let s = merged.committed[cseq] {
                    results.append(.ack(cseq: cseq, seq: s))
                } else {
                    results.append(.reject(cseq: cseq, reason: merged.rejected[cseq] ?? .notCommitted))
                }
                continue
            }
            if cseq > high + 1 && !defects.contains(.noDedup) {
                results.append(.gap(cseq: cseq, expected: high + 1))
                continue
            }
            // A new op, in order. Whatever happens, it advances the client's cseq.
            do throws(RejectReason) {
                guard let op = inc.op else { throw RejectReason.invalid(inc.decodeError ?? "malformed op") }
                guard inc.base >= 0, inc.base <= seq else { throw RejectReason.invalid("base \(inc.base) is outside 0...\(seq)") }
                try doc.validate(op, base: inc.base, by: req.client,
                                 checkConflicts: !defects.contains(.skipStaleCheck), defects: defects)
                seq += 1
                let entry = LogEntry(seq: seq, client: req.client, cseq: cseq, base: inc.base, op: op)
                doc.apply(op, at: entry.stamp, defects: defects)
                entries.append(entry)
                merged.committed[cseq] = seq
                results.append(.ack(cseq: cseq, seq: seq))
            } catch {
                rejections[cseq] = error
                merged.rejected[cseq] = error
                results.append(.reject(cseq: cseq, reason: error))
            }
            high = max(high, cseq)
            highChanged = highChanged || high > clientHigh
        }
        highChanged = high > clientHigh

        var knownOut: KnownOutcomes?
        if let from = req.resolveFrom {
            knownOut = KnownOutcomes(committed: merged.committed.filter { $0.key >= from && $0.key <= high },
                                     rejected: merged.rejected.filter { $0.key >= from && $0.key <= high })
        }
        return SequencerBatch(response: SubmitResponse(head: seq, high: high, results: results, known: knownOut),
                              entries: entries, rejections: rejections, newHigh: high, highChanged: highChanged)
    }

    /// True when a snapshot should be written because `newSeq` crossed a multiple of `every` after `oldSeq`.
    public static func snapshotDue(oldSeq: Int, newSeq: Int, every: Int) -> Bool {
        every > 0 && newSeq / every > oldSeq / every
    }
}
