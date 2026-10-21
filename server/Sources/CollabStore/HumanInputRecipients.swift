import Foundation
import PostgresNIO

/// An email recipient of a human-input form (protocol 1.16, Dify's `HumanInputFormRecipient`): the person a link was
/// mailed to, with the **token that link carries** — one per recipient, so an external person answers without an account
/// and the answer is attributable. `mailedAt` makes delivery idempotent: a restart, or a later pause adopting the same
/// waiting form, sends nothing twice.
public struct StoredFormRecipient: Sendable, Equatable {
    /// The token in the link (`/form/{token}`), unique per recipient.
    public var token: String
    public var formId: String
    /// The run whose pause the form belongs to; nil for a delivery test.
    public var workflowRunId: String?
    /// The index of the node's delivery method that named this recipient (its subject and body).
    public var methodIndex: Int
    /// `member` (a workspace account, `referenceId`) or `external` (an address).
    public var type: String
    public var referenceId: String?
    public var email: String
    public var mailedAt: Date?
    /// Set when this recipient's link answered the form.
    public var usedAt: Date?
    public var createdAt: Date

    public init(token: String, formId: String, workflowRunId: String?, methodIndex: Int, type: String,
                referenceId: String? = nil, email: String, mailedAt: Date? = nil, usedAt: Date? = nil, createdAt: Date) {
        self.token = token
        self.formId = formId
        self.workflowRunId = workflowRunId
        self.methodIndex = methodIndex
        self.type = type
        self.referenceId = referenceId
        self.email = email
        self.mailedAt = mailedAt
        self.usedAt = usedAt
        self.createdAt = createdAt
    }
}

extension PostgresStore {
    static let recipientColumns = """
        token, form_id, workflow_run_id, method_index, recipient_type, reference_id, email, mailed_at, used_at, created_at
        """

    static func decodeRecipient(_ row: PostgresRow) throws -> StoredFormRecipient {
        let r = row.makeRandomAccess()
        return StoredFormRecipient(
            token: try r[0].decode(String.self), formId: try r[1].decode(String.self),
            workflowRunId: try r[2].decode(String?.self), methodIndex: try r[3].decode(Int.self),
            type: try r[4].decode(String.self), referenceId: try r[5].decode(String?.self),
            email: try r[6].decode(String.self), mailedAt: try r[7].decode(Date?.self),
            usedAt: try r[8].decode(Date?.self), createdAt: try r[9].decode(Date.self))
    }

    /// Adds recipients to a form, keeping the ones already there (a later pause adopts a waiting form, and its recipients
    /// keep the links they were given).
    public func addFormRecipients(_ recipients: [StoredFormRecipient]) async throws {
        guard !recipients.isEmpty else { return }
        try await bounded {
            for r in recipients {
                _ = try await self.client.query("""
                    INSERT INTO human_input_form_recipients (\(unescaped: Self.recipientColumns))
                    VALUES (\(r.token), \(r.formId), \(r.workflowRunId), \(r.methodIndex), \(r.type), \(r.referenceId),
                        \(r.email), \(r.mailedAt), \(r.usedAt), \(r.createdAt))
                    ON CONFLICT (form_id, email) DO NOTHING
                    """, logger: self.logger)
            }
        }
    }

    public func formRecipients(formId: String) async throws -> [StoredFormRecipient] {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT \(unescaped: Self.recipientColumns) FROM human_input_form_recipients
                WHERE form_id = \(formId) ORDER BY created_at, email
                """, logger: self.logger)
            var out: [StoredFormRecipient] = []
            for try await row in rows { out.append(try Self.decodeRecipient(row)) }
            return out
        }
    }

    /// The recipients whose link was never mailed, oldest first: what a delivery (and a retry after a restart) sends.
    public func formRecipientsAwaitingMail(limit: Int = 500) async throws -> [StoredFormRecipient] {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT \(unescaped: Self.recipientColumns) FROM human_input_form_recipients
                WHERE mailed_at IS NULL ORDER BY created_at LIMIT \(limit)
                """, logger: self.logger)
            var out: [StoredFormRecipient] = []
            for try await row in rows { out.append(try Self.decodeRecipient(row)) }
            return out
        }
    }

    /// How many recipient rows are still waiting for their mail (what the scan will try).
    public func humanInputFormsAwaitingMailCount() async throws -> Int {
        try await bounded {
            for try await n in try await self.client.query(
                "SELECT count(*)::bigint FROM human_input_form_recipients WHERE mailed_at IS NULL",
                logger: self.logger).decode(Int.self) {
                return n
            }
            return 0
        }
    }

    /// The row as a crash between "recipient stored" and "mail sent" leaves it (a test's way back to that state).
    public func resetFormRecipientMailed(token: String) async throws {
        try await bounded {
            _ = try await self.client.query("""
                UPDATE human_input_form_recipients SET mailed_at = NULL WHERE token = \(token)
                """, logger: self.logger)
        }
    }

    public func markFormRecipientMailed(token: String, at: Date) async throws {
        try await bounded {
            _ = try await self.client.query("""
                UPDATE human_input_form_recipients SET mailed_at = \(at) WHERE token = \(token) AND mailed_at IS NULL
                """, logger: self.logger)
        }
    }

    /// The recipient a link's token names, with its form (nil for an unknown token).
    public func formRecipient(token: String) async throws -> (recipient: StoredFormRecipient, form: StoredHumanInputForm)? {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT r.token, r.form_id, r.workflow_run_id, r.method_index, r.recipient_type, r.reference_id, r.email,
                       r.mailed_at, r.used_at, r.created_at, \(unescaped: Self.formColumnsQualified)
                FROM human_input_form_recipients r JOIN human_input_forms f ON f.id = r.form_id
                WHERE r.token = \(token)
                """, logger: self.logger)
            for try await row in rows {
                let recipient = try Self.decodeRecipient(row)
                // The form's columns start after the recipient's ten.
                let form = try Self.decodeForm(row, offset: 10)
                return (recipient, form)
            }
            return nil
        }
    }

    /// The recipient's link answered the form.
    public func markFormRecipientUsed(token: String, at: Date) async throws {
        try await bounded {
            _ = try await self.client.query("""
                UPDATE human_input_form_recipients SET used_at = coalesce(used_at, \(at)) WHERE token = \(token)
                """, logger: self.logger)
        }
    }
}
