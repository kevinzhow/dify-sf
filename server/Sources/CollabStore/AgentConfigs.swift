// Private inline Agent v2 resources. Graph ops and these rows commit under the same document revision fence.
import CollabCore
import Foundation
import PostgresNIO

public struct StoredAgentConfig: Sendable, Equatable {
    public var id: String
    public var agentId: String
    public var bindingId: String
    public var docId: String
    public var nodeId: String
    public var revision: Int
    /// Soul JSON with secret references, never plaintext credentials.
    public var soul: String
    public var nodeJob: String
    public var displayVersion: Int
    public var versionNote: String
    public var createdBy: String
    public var createdAt: Date

    public init(id: String, agentId: String, bindingId: String, docId: String, nodeId: String,
                revision: Int, soul: String, createdBy: String, createdAt: Date, nodeJob: String = "{}", displayVersion: Int = 1, versionNote: String = "") {
        self.id = id; self.agentId = agentId; self.bindingId = bindingId; self.docId = docId
        self.nodeId = nodeId; self.revision = revision; self.soul = soul
        self.versionNote = versionNote; self.createdBy = createdBy; self.createdAt = createdAt; self.nodeJob = nodeJob; self.displayVersion = displayVersion
    }
}

/// Written only by DocumentSequencer.replace, with the binding's graph ops and sealed secret rows.
public struct AgentConfigCommit: Sendable {
    public var snapshot: StoredAgentConfig
    /// nil creates a binding; otherwise exactly this prior snapshot must still be current.
    public var expectedSnapshotId: String?
    public var receipt: AgentComposerReceipt
    public init(snapshot: StoredAgentConfig, expectedSnapshotId: String?, receipt: AgentComposerReceipt) {
        self.snapshot = snapshot; self.expectedSnapshotId = expectedSnapshotId; self.receipt = receipt
    }
}

/// The exact masked response and canonical request digest commit with the graph ops. Retries never mint another revision.
public struct AgentComposerReceipt: Sendable {
    public var requestID: String
    public var userID: String
    public var nodeID: String
    public var digest: String
    public var response: String
    public init(requestID: String, userID: String, nodeID: String, digest: String, response: String) {
        self.requestID = requestID; self.userID = userID; self.nodeID = nodeID; self.digest = digest; self.response = response
    }
}

extension PostgresStore {
    /// An ID in an imported graph is never sufficient to read a different app/node's private Soul.
    public func agentConfig(doc: String, node: String, agent: String, snapshot: String) async throws -> StoredAgentConfig? {
        try await bounded {
            for try await (id, agentId, bindingId, docId, nodeId, revision, soul, user, at, job, displayVersion, note) in try await self.client.query("""
                SELECT id, agent_id, binding_id, doc_id, node_id, revision, soul::text, created_by, created_at, node_job::text, display_version, version_note
                FROM agent_config_snapshots WHERE id = \(snapshot) AND doc_id = \(doc)
                  AND node_id = \(node) AND agent_id = \(agent)
                """, logger: self.logger).decode((String, String, String, String, String, Int, String, String, Date, String, Int, String).self) {
                return StoredAgentConfig(id: id, agentId: agentId, bindingId: bindingId, docId: docId, nodeId: nodeId,
                                         revision: revision, soul: soul, createdBy: user, createdAt: at, nodeJob: job, displayVersion: displayVersion, versionNote: note)
            }
            return nil
        }
    }

    /// The graph's snapshot remains authoritative after restore/copy. This pointer is only the composer draft's CAS.
    public func currentAgentConfig(doc: String, node: String) async throws -> StoredAgentConfig? {
        try await bounded {
            for try await (id, agentId, bindingId, docId, nodeId, revision, soul, user, at, job, displayVersion, note) in try await self.client.query("""
                SELECT s.id, s.agent_id, s.binding_id, s.doc_id, s.node_id, s.revision, s.soul::text, s.created_by, s.created_at, s.node_job::text, s.display_version, s.version_note
                FROM agent_config_snapshots s JOIN workflow_agent_bindings b ON b.current_snapshot_id = s.id
                WHERE b.doc_id = \(doc) AND b.node_id = \(node)
                """, logger: self.logger).decode((String, String, String, String, String, Int, String, String, Date, String, Int, String).self) {
                return StoredAgentConfig(id: id, agentId: agentId, bindingId: bindingId, docId: docId, nodeId: nodeId,
                                         revision: revision, soul: soul, createdBy: user, createdAt: at, nodeJob: job, displayVersion: displayVersion, versionNote: note)
            }
            return nil
        }
    }

    public func agentComposerReceipt(doc: String, user: String, request: String) async throws -> AgentComposerReceipt? {
        try await bounded {
            for try await (node, digest, response) in try await self.client.query("""
                SELECT node_id, digest, response_json::text FROM agent_composer_receipts
                WHERE doc_id = \(doc) AND user_id = \(user) AND request_id = \(request)
                """, logger: self.logger).decode((String, String, String).self) {
                return AgentComposerReceipt(requestID: request, userID: user, nodeID: node, digest: digest, response: response)
            }
            return nil
        }
    }

    func commitAgentConfig(_ change: AgentConfigCommit, doc: String, tx: PostgresConnection) async throws {
        let s = change.snapshot
        guard s.docId == doc, !s.id.isEmpty, !s.agentId.isEmpty, !s.bindingId.isEmpty,
              !s.nodeId.isEmpty, s.revision >= 1,
              let bytes = s.soul.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: bytes)) is [String: Any] else {
            throw StoreError.notCommitted("Invalid agent config resource")
        }
        var current: String?
        var currentBinding: String?
        var currentAgent: String?
        var currentRevision = 0
        for try await (snapshotId, bindingId, agentId) in try await tx.query("""
            SELECT b.current_snapshot_id, b.id, b.agent_id FROM workflow_agent_bindings b
            WHERE b.doc_id = \(doc) AND b.node_id = \(s.nodeId) FOR UPDATE
            """, logger: logger).decode((String, String, String).self) {
            current = snapshotId; currentBinding = bindingId; currentAgent = agentId
        }
        guard current == change.expectedSnapshotId,
              current == nil || (currentBinding == s.bindingId && currentAgent == s.agentId) else {
            throw StoreError.revisionMismatch
        }
        if let current {
            for try await revision in try await tx.query("SELECT revision FROM agent_config_snapshots WHERE id = \(current)", logger: logger).decode(Int.self) { currentRevision = revision }
        }
        guard s.revision == currentRevision + 1, s.displayVersion >= 1 else { throw StoreError.revisionMismatch }
        if current == nil {
            _ = try await tx.query("""
                INSERT INTO inline_agents(id, doc_id, node_id, created_by, created_at)
                VALUES (\(s.agentId), \(doc), \(s.nodeId), \(s.createdBy), \(s.createdAt))
                """, logger: logger)
        }
        // No upsert: immutable snapshots may never be overwritten, including a request retried with another payload.
        _ = try await tx.query("""
            INSERT INTO agent_config_snapshots(id, agent_id, binding_id, doc_id, node_id, revision, soul, created_by, created_at, node_job, display_version, version_note)
            VALUES (\(s.id), \(s.agentId), \(s.bindingId), \(doc), \(s.nodeId), \(s.revision), \(s.soul)::jsonb, \(s.createdBy), \(s.createdAt), \(s.nodeJob)::jsonb, \(s.displayVersion), \(s.versionNote))
            """, logger: logger)
        _ = try await tx.query("""
            INSERT INTO workflow_agent_bindings(id, agent_id, doc_id, node_id, current_snapshot_id)
            VALUES (\(s.bindingId), \(s.agentId), \(doc), \(s.nodeId), \(s.id))
            ON CONFLICT (doc_id, node_id) DO UPDATE SET current_snapshot_id = EXCLUDED.current_snapshot_id
            """, logger: logger)
        let receipt = change.receipt
        guard receipt.nodeID == s.nodeId, receipt.userID == s.createdBy, !receipt.requestID.isEmpty else {
            throw StoreError.notCommitted("Invalid agent composer receipt")
        }
        // Composer changes are document operations too; collaborators must see the authenticated editor's name.
        let client = "agent-" + receipt.userID + "-" + receipt.requestID
        _ = try await tx.query("""
            INSERT INTO client_accounts(doc_id, client_id, account_id) VALUES (\(doc), \(client), \(receipt.userID))
            ON CONFLICT (doc_id, client_id) DO NOTHING
            """, logger: logger)
        _ = try await tx.query("""
            INSERT INTO agent_composer_receipts(doc_id, user_id, request_id, node_id, digest, response_json)
            VALUES (\(doc), \(receipt.userID), \(receipt.requestID), \(receipt.nodeID), \(receipt.digest), \(receipt.response)::jsonb)
            """, logger: logger)
    }
}


extension PostgresStore {
    /// Bind only the immutable IDs in the exact published graph, never the latest draft pointers.
    func publishAgentBindings(doc: String, version: String, state: String, tx: PostgresConnection) async throws {
        let document = try WireJSON.decode(Document.self, from: Data(state.utf8))
        for node in document.nodes.values where node.type == "agent" && node.config["version"] == .string("2") {
            guard case .map(let binding)? = node.config["agent_binding"], binding["binding_type"] == .string("inline_agent"),
                  case .string(let agent)? = binding["agent_id"], case .string(let snapshot)? = binding["current_snapshot_id"] else {
                throw StoreError.notCommitted("A published Agent v2 node needs an inline config")
            }
            var found = false
            for try await _ in try await tx.query("""
                SELECT 1 FROM agent_config_snapshots WHERE id = \(snapshot) AND doc_id = \(doc)
                  AND node_id = \(node.id) AND agent_id = \(agent)
                """, logger: logger) { found = true }
            guard found else { throw StoreError.notCommitted("An agent snapshot does not belong to the published node") }
            _ = try await tx.query("""
                INSERT INTO workflow_agent_published_bindings(version_id, node_id, snapshot_id)
                VALUES (\(version), \(node.id), \(snapshot))
                """, logger: logger)
        }
    }

    public func publishedAgentSnapshot(version: String, node: String) async throws -> String? {
        try await bounded {
            for try await id in try await self.client.query("""
                SELECT snapshot_id FROM workflow_agent_published_bindings WHERE version_id = \(version) AND node_id = \(node)
                """, logger: self.logger).decode(String.self) { return id }
            return nil
        }
    }
}
