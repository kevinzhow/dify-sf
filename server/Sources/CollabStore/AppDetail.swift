import CollabCore
import Foundation
import PostgresNIO

/// Dify's site languages (`constants/languages.py`), in Dify's order. The first is the fallback (Dify's
/// `get_valid_language`).
public enum SiteLanguages {
    public static let all = ["en-US", "zh-Hans", "zh-Hant", "pt-BR", "es-ES", "fr-FR", "de-DE", "ja-JP", "ko-KR", "lo-LA", "ru-RU",
                             "it-IT", "uk-UA", "vi-VN", "ro-RO", "pl-PL", "hi-IN", "tr-TR", "fa-IR", "sl-SI", "th-TH", "id-ID",
                             "ar-TN", "nl-NL"]
}

/// Changes to a site (Dify's `AppSiteChanges`): nil members keep their value.
public struct SiteChanges: Sendable, Equatable {
    public var title: String?
    public var iconType: String?
    public var icon: String?
    public var iconBackground: String?
    public var description: String?
    public var defaultLanguage: String?
    public var chatColorTheme: String?
    public var chatColorThemeInverted: Bool?
    public var customizeDomain: String?
    public var copyright: String?
    public var privacyPolicy: String?
    public var inputPlaceholder: String?
    public var customDisclaimer: String?
    public var customizeTokenStrategy: String?
    public var promptPublic: Bool?
    public var showWorkflowSteps: Bool?
    public var useIconAsAnswerIcon: Bool?
    public init() {}
}

/// A Service API key as stored: the token is decrypted (nil when it cannot be: no or another secrets key).
public struct StoredApiKey: Sendable, Equatable {
    public var id: String
    public var token: String?
    public var lastUsedAt: Date?
    public var createdAt: Date
    public init(id: String, token: String?, lastUsedAt: Date?, createdAt: Date) {
        self.id = id
        self.token = token
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
    }
}

public struct StoredAnnotation: Sendable, Equatable {
    public var id: String
    public var question: String
    public var answer: String
    public var hitCount: Int
    public var createdAt: Date
}

public struct StoredAnnotationSetting: Sendable, Equatable {
    public var id: String
    public var scoreThreshold: Double
    public var embeddingProviderName: String
    public var embeddingModelName: String
}

/// A published version. `state` is the document (as `snapshots.state`), `dsl` its Dify metadata (as `doc_meta.dsl`), both
/// JSON text.
public struct StoredVersion: Sendable, Equatable {
    public struct Account: Sendable, Equatable {
        public var id: String
        public var name: String
        public var email: String
    }
    public var id: String
    public var number: Int
    public var version: String
    public var seq: Int
    public var state: String
    public var dsl: String
    public var hash: String
    public var markedName: String
    public var markedComment: String
    public var createdBy: Account?
    public var createdAt: Date
    public var updatedBy: Account?
    public var updatedAt: Date
}

public enum ApiKeyCreation: Sendable, Equatable {
    case created(createdAt: Date)
    /// The app has `max` keys already.
    case limit
    /// Unknown or deleted app.
    case missing
}

/// What a member's like / dislike did (Dify's `_update_message_feedback`).
public enum AdminFeedbackOutcome: Sendable, Equatable {
    case created
    case updated
    case deleted
    /// No message of that id in this app.
    case noMessage
    /// No rating and no admin feedback to remove.
    case nothingToClear
}

/// What setting a Web App / Service API switch did.
public enum SwitchOutcome: Sendable, Equatable {
    case changed
    /// It had that value already.
    case unchanged
    /// Unknown or deleted app.
    case missing
}

public enum VersionDeletion: Sendable, Equatable {
    case deleted
    case missing
    /// The app's published (newest) version.
    case inUse
}

/// App detail pages (protocol 1.11): the Web App site, the switches, Service API keys, annotations and their reply setting,
/// annotation jobs, published versions. Every operation is bounded by `operationTimeout`.
extension PostgresStore {
    /// How long a job's state is kept (Dify's Redis `setex(..., 600, ...)`).
    public static let jobSeconds = 600

    static let siteLanguagesSQL = "ARRAY[" + SiteLanguages.all.map { "'\($0)'" }.joined(separator: ",") + "]::text[]"

    /// Dify's `generate_string(16)`: letters and digits.
    static func siteCode() -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<16).map { _ in letters[Int.random(in: 0..<letters.count, using: &rng)] })
    }

    // MARK: - Sites

    /// Inserts the site of a new app in transaction `tx` (Dify's `create_site_record_when_app_created`): title and icon from
    /// the app, the creator's interface language (else `en-US`), a fresh code.
    func insertSite(_ tx: PostgresConnection, id: String, name: String, iconType: String?, icon: String?, iconBackground: String?,
                    createdBy: String?) async throws {
        for _ in 0..<8 {
            let code = Self.siteCode()
            let rows = try await tx.query("""
                INSERT INTO app_sites (doc_id, code, title, icon_type, icon, icon_background, default_language, created_by, updated_by)
                VALUES (\(id), \(code), \(name), \(iconType), \(icon), \(iconBackground),
                        COALESCE((SELECT acc.interface_language FROM accounts acc
                                  WHERE acc.id = \(createdBy) AND acc.interface_language = ANY(\(unescaped: Self.siteLanguagesSQL))), 'en-US'),
                        \(createdBy), \(createdBy))
                ON CONFLICT DO NOTHING RETURNING 1
                """, logger: logger)
            for try await _ in rows { return }
            // A taken code (or a site that exists already).
            for try await _ in try await tx.query("SELECT 1 FROM app_sites WHERE doc_id = \(id)", logger: logger) { return }
        }
        throw StoreError.corrupt("could not draw a free site code")
    }

    /// Protocol 1.11 migration: a site for every app without one (deleted apps included; idempotent; run at startup).
    @discardableResult
    public func backfillSites() async throws -> Int {
        try await bounded {
            var missing: [(String, String, String?, String?, String?, String?)] = []
            for try await r in try await self.client.query("""
                SELECT a.doc_id, a.name, a.icon_type, a.icon, a.icon_background, a.created_by FROM apps a
                WHERE NOT EXISTS (SELECT 1 FROM app_sites s WHERE s.doc_id = a.doc_id) ORDER BY a.doc_id
                """, logger: self.logger).decode((String, String, String?, String?, String?, String?).self) { missing.append(r) }
            for m in missing {
                try await self.client.withConnection { c in
                    try await self.insertSite(c, id: m.0, name: m.1, iconType: m.2, icon: m.3, iconBackground: m.4, createdBy: m.5)
                }
            }
            return missing.count
        }
    }

    /// The site's columns as one JSON object (Dify's member names; `code` also as `access_token`), nil if none.
    static let siteJSONSQL = """
        (SELECT jsonb_build_object('app_id', s.doc_id, 'access_token', s.code, 'code', s.code, 'title', s.title,
                'icon_type', s.icon_type, 'icon', s.icon, 'icon_background', s.icon_background, 'description', s.description,
                'default_language', s.default_language, 'chat_color_theme', s.chat_color_theme,
                'chat_color_theme_inverted', s.chat_color_theme_inverted, 'customize_domain', s.customize_domain,
                'copyright', s.copyright, 'privacy_policy', s.privacy_policy, 'input_placeholder', s.input_placeholder,
                'custom_disclaimer', s.custom_disclaimer, 'customize_token_strategy', s.customize_token_strategy,
                'prompt_public', s.prompt_public, 'show_workflow_steps', s.show_workflow_steps,
                'use_icon_as_answer_icon', s.use_icon_as_answer_icon, 'created_by', s.created_by, 'updated_by', s.updated_by,
                'created_at', floor(extract(epoch FROM s.created_at))::bigint, 'updated_at', floor(extract(epoch FROM s.updated_at))::bigint)::text
         FROM app_sites s WHERE s.doc_id = a.doc_id)
        """

    /// The site of a live app as JSON text (see `siteJSONSQL`); nil for an unknown or deleted app or one without a site.
    public func siteJSON(_ id: String) async throws -> String? {
        try await bounded {
            for try await (json) in try await self.client.query("""
                SELECT \(unescaped: Self.siteJSONSQL) FROM apps a WHERE a.doc_id = \(id) AND a.deleted_at IS NULL
                """, logger: self.logger).decode(String?.self) { return json }
            return nil
        }
    }

    /// Dify's site update (`AppSiteCommandRepository.update_site`): nil members keep their value. False for an unknown or
    /// deleted app.
    public func updateSite(_ id: String, _ c: SiteChanges, by: String) async throws -> Bool {
        try await bounded {
            let rows = try await self.client.query("""
                UPDATE app_sites s SET
                    title = COALESCE(\(c.title), title), icon_type = COALESCE(\(c.iconType), icon_type), icon = COALESCE(\(c.icon), icon),
                    icon_background = COALESCE(\(c.iconBackground), icon_background), description = COALESCE(\(c.description), description),
                    default_language = COALESCE(\(c.defaultLanguage), default_language),
                    chat_color_theme = COALESCE(\(c.chatColorTheme), chat_color_theme),
                    chat_color_theme_inverted = COALESCE(\(c.chatColorThemeInverted), chat_color_theme_inverted),
                    customize_domain = COALESCE(\(c.customizeDomain), customize_domain), copyright = COALESCE(\(c.copyright), copyright),
                    privacy_policy = COALESCE(\(c.privacyPolicy), privacy_policy),
                    input_placeholder = COALESCE(\(c.inputPlaceholder), input_placeholder),
                    custom_disclaimer = COALESCE(\(c.customDisclaimer), custom_disclaimer),
                    customize_token_strategy = COALESCE(\(c.customizeTokenStrategy), customize_token_strategy),
                    prompt_public = COALESCE(\(c.promptPublic), prompt_public),
                    show_workflow_steps = COALESCE(\(c.showWorkflowSteps), show_workflow_steps),
                    use_icon_as_answer_icon = COALESCE(\(c.useIconAsAnswerIcon), use_icon_as_answer_icon),
                    updated_by = \(by), updated_at = now()
                WHERE s.doc_id = \(id) AND EXISTS (SELECT 1 FROM apps a WHERE a.doc_id = s.doc_id AND a.deleted_at IS NULL)
                RETURNING 1
                """, logger: self.logger)
            for try await _ in rows { return true }
            return false
        }
    }

    /// A new site code (Dify's access-token reset). False for an unknown or deleted app.
    public func resetSiteCode(_ id: String, by: String) async throws -> Bool {
        try await bounded {
            for _ in 0..<8 {
                let code = Self.siteCode()
                var taken = false
                for try await _ in try await self.client.query("SELECT 1 FROM app_sites WHERE code = \(code)", logger: self.logger) { taken = true }
                if taken { continue }
                let rows = try await self.client.query("""
                    UPDATE app_sites s SET code = \(code), updated_by = \(by), updated_at = now()
                    WHERE s.doc_id = \(id) AND EXISTS (SELECT 1 FROM apps a WHERE a.doc_id = s.doc_id AND a.deleted_at IS NULL)
                    RETURNING 1
                    """, logger: self.logger)
                for try await _ in rows { return true }
                return false
            }
            throw StoreError.corrupt("could not draw a free site code")
        }
    }

    /// Sets `enable_site` or `enable_api` (Dify's `update_app_site_status` / `update_app_api_status`: a change also sets
    /// `updated_by` / `updated_at`; the same value changes nothing).
    public func setAppSwitch(_ id: String, api: Bool, enabled: Bool, by: String) async throws -> SwitchOutcome {
        let column = api ? "enable_api" : "enable_site"
        return try await bounded {
            try await self.client.withTransaction(logger: self.logger) { tx in
                var was: Bool?
                for try await v in try await tx.query("""
                    SELECT \(unescaped: column) FROM apps WHERE doc_id = \(id) AND deleted_at IS NULL FOR UPDATE
                    """, logger: self.logger).decode(Bool.self) { was = v }
                guard let was else { return .missing }
                if was == enabled { return .unchanged }
                _ = try await tx.query("""
                    UPDATE apps SET \(unescaped: column) = \(enabled), updated_by = \(by), updated_at = now() WHERE doc_id = \(id)
                    """, logger: self.logger)
                return .changed
            }
        }
    }

    // MARK: - Service API keys

    func apiKeyContext(doc: String, id: String) -> String { "app_api_key:\(doc):\(id)" }

    /// The keys of app `doc`, oldest first, decrypted where possible.
    public func apiKeys(_ doc: String) async throws -> [StoredApiKey] {
        try await bounded {
            var out: [StoredApiKey] = []
            for try await (id, sealed, used, created) in try await self.client.query("""
                SELECT id, sealed_token, last_used_at, created_at FROM app_api_keys WHERE doc_id = \(doc) ORDER BY created_at, id
                """, logger: self.logger).decode((String, String, Date?, Date).self) {
                var token: String?
                if let cipher = self.cipher { token = try? cipher.open(sealed, context: self.apiKeyContext(doc: doc, id: id)) }
                out.append(StoredApiKey(id: id, token: token, lastUsedAt: used, createdAt: created))
            }
            return out
        }
    }

    /// Stores a new key (sealed; `tokenHash` = SHA-256 hex of the token) unless the app has `max` keys. Throws
    /// `SecretsKeyMissing` without a cipher.
    public func createApiKey(_ doc: String, id: String, token: String, tokenHash: String, by: String?, max: Int) async throws -> ApiKeyCreation {
        guard let cipher else { throw SecretsKeyMissing() }
        let sealed = try cipher.seal(token, context: apiKeyContext(doc: doc, id: id))
        return try await bounded {
            try await self.client.withTransaction(logger: self.logger) { tx in
                var live = false
                for try await _ in try await tx.query(
                    "SELECT 1 FROM apps WHERE doc_id = \(doc) AND deleted_at IS NULL FOR UPDATE", logger: self.logger) { live = true }
                guard live else { return .missing }
                var n = 0
                for try await c in try await tx.query("SELECT count(*)::bigint FROM app_api_keys WHERE doc_id = \(doc)", logger: self.logger)
                    .decode(Int.self) { n = c }
                if n >= max { return .limit }
                for try await created in try await tx.query("""
                    INSERT INTO app_api_keys (id, doc_id, token_hash, sealed_token, created_by)
                    VALUES (\(id), \(doc), \(tokenHash), \(sealed), \(by)) RETURNING created_at
                    """, logger: self.logger).decode(Date.self) { return .created(createdAt: created) }
                throw StoreError.corrupt("key insert returned nothing")
            }
        }
    }

    /// Deletes key `keyId` of app `doc`. False if there is none.
    public func deleteApiKey(_ doc: String, keyId: String) async throws -> Bool {
        try await bounded {
            for try await _ in try await self.client.query(
                "DELETE FROM app_api_keys WHERE doc_id = \(doc) AND id = \(keyId) RETURNING 1", logger: self.logger) { return true }
            return false
        }
    }

    /// The runtime's lookup: the app and key of a token by its SHA-256 (hex), for a live app only. nil if unknown.
    public func apiKey(byHash tokenHash: String) async throws -> (doc: String, id: String)? {
        try await bounded {
            for try await (doc, id) in try await self.client.query("""
                SELECT k.doc_id, k.id FROM app_api_keys k JOIN apps a ON a.doc_id = k.doc_id
                WHERE k.token_hash = \(tokenHash) AND a.deleted_at IS NULL
                """, logger: self.logger).decode((String, String).self) { return (doc, id) }
            return nil
        }
    }

    // MARK: - Annotations

    func decodeAnnotations(_ rows: PostgresRowSequence) async throws -> [StoredAnnotation] {
        var out: [StoredAnnotation] = []
        for try await r in rows.decode((String, String, String, Int, Date).self) {
            out.append(StoredAnnotation(id: r.0, question: r.1, answer: r.2, hitCount: r.3, createdAt: r.4))
        }
        return out
    }

    /// One page of app `doc`'s annotations, newest first, matching `keyword` (case-insensitive substring of question or
    /// answer; Dify's `ilike`), and how many match.
    public func annotations(_ doc: String, page: Int, limit: Int, keyword: String?) async throws -> (total: Int, rows: [StoredAnnotation]) {
        try await bounded {
            let k = keyword.flatMap { $0.isEmpty ? nil : $0.lowercased() }
            var total = 0
            for try await n in try await self.client.query("""
                SELECT count(*)::bigint FROM app_annotations WHERE doc_id = \(doc)
                  AND (\(k)::text IS NULL OR strpos(lower(question), \(k)) > 0 OR strpos(lower(content), \(k)) > 0)
                """, logger: self.logger).decode(Int.self) { total = n }
            let offset = max(0, (page - 1) * limit)
            let rows = try await self.decodeAnnotations(try await self.client.query("""
                SELECT id, question, content, hit_count::bigint, created_at FROM app_annotations WHERE doc_id = \(doc)
                  AND (\(k)::text IS NULL OR strpos(lower(question), \(k)) > 0 OR strpos(lower(content), \(k)) > 0)
                ORDER BY created_at DESC, id DESC LIMIT \(unescaped: String(max(0, limit))) OFFSET \(unescaped: String(offset))
                """, logger: self.logger))
            return (total, rows)
        }
    }

    public func annotationCount(_ doc: String) async throws -> Int {
        try await bounded {
            for try await n in try await self.client.query("SELECT count(*)::bigint FROM app_annotations WHERE doc_id = \(doc)",
                                                           logger: self.logger).decode(Int.self) { return n }
            return 0
        }
    }

    /// Every annotation of app `doc`, newest first.
    public func allAnnotations(_ doc: String) async throws -> [StoredAnnotation] {
        try await bounded {
            try await self.decodeAnnotations(try await self.client.query("""
                SELECT id, question, content, hit_count::bigint, created_at FROM app_annotations WHERE doc_id = \(doc)
                ORDER BY created_at DESC, id DESC
                """, logger: self.logger))
        }
    }

    public func annotation(_ doc: String, id: String) async throws -> StoredAnnotation? {
        try await bounded {
            try await self.decodeAnnotations(try await self.client.query("""
                SELECT id, question, content, hit_count::bigint, created_at FROM app_annotations WHERE doc_id = \(doc) AND id = \(id)
                """, logger: self.logger)).first
        }
    }

    /// Inserts annotations (one transaction; in the given order, each a little later than the one before).
    @discardableResult
    public func insertAnnotations(_ doc: String, _ rows: [(id: String, question: String, answer: String)], account: String?) async throws -> [StoredAnnotation] {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { tx in
                var out: [StoredAnnotation] = []
                // In chunks: one statement per 500 rows (unnest of three arrays).
                var i = 0
                while i < rows.count {
                    let chunk = rows[i..<min(rows.count, i + 500)]
                    let ids = chunk.map(\.id), qs = chunk.map(\.question), ans = chunk.map(\.answer)
                    out += try await self.decodeAnnotations(try await tx.query("""
                        INSERT INTO app_annotations (id, doc_id, question, content, account_id)
                        SELECT x.id, \(doc), x.q, x.a, \(account) FROM unnest(\(ids)::text[], \(qs)::text[], \(ans)::text[]) WITH ORDINALITY AS x(id, q, a, n)
                        ORDER BY x.n
                        RETURNING id, question, content, hit_count::bigint, created_at
                        """, logger: self.logger))
                    i += 500
                }
                return out
            }
        }
    }

    /// Dify's `update_app_annotation_directly`. nil if there is no such annotation.
    public func updateAnnotation(_ doc: String, id: String, question: String, answer: String) async throws -> StoredAnnotation? {
        try await bounded {
            try await self.decodeAnnotations(try await self.client.query("""
                UPDATE app_annotations SET question = \(question), content = \(answer), updated_at = clock_timestamp()
                WHERE doc_id = \(doc) AND id = \(id) RETURNING id, question, content, hit_count::bigint, created_at
                """, logger: self.logger)).first
        }
    }

    /// Deletes annotations of app `doc`: those of `ids`, or all with nil. Returns how many.
    @discardableResult
    public func deleteAnnotations(_ doc: String, ids: [String]?) async throws -> Int {
        try await bounded {
            let rows: PostgresRowSequence
            if let ids {
                rows = try await self.client.query(
                    "DELETE FROM app_annotations WHERE doc_id = \(doc) AND id = ANY(\(ids)::text[]) RETURNING 1", logger: self.logger)
            } else {
                rows = try await self.client.query("DELETE FROM app_annotations WHERE doc_id = \(doc) RETURNING 1", logger: self.logger)
            }
            var n = 0
            for try await _ in rows { n += 1 }
            return n
        }
    }

    public func annotationSetting(_ doc: String) async throws -> StoredAnnotationSetting? {
        try await bounded {
            for try await r in try await self.client.query("""
                SELECT id, score_threshold, embedding_provider_name, embedding_model_name FROM app_annotation_settings WHERE doc_id = \(doc)
                """, logger: self.logger).decode((String, Double, String, String).self) {
                return StoredAnnotationSetting(id: r.0, scoreThreshold: r.1, embeddingProviderName: r.2, embeddingModelName: r.3)
            }
            return nil
        }
    }

    /// Dify's enable job: creates the setting or updates it (keeping its id).
    public func enableAnnotationReply(_ doc: String, newId: String, scoreThreshold: Double, provider: String, model: String, by: String) async throws {
        try await bounded {
            _ = try await self.client.query("""
                INSERT INTO app_annotation_settings (doc_id, id, score_threshold, embedding_provider_name, embedding_model_name, created_by, updated_by)
                VALUES (\(doc), \(newId), \(scoreThreshold), \(provider), \(model), \(by), \(by))
                ON CONFLICT (doc_id) DO UPDATE SET score_threshold = EXCLUDED.score_threshold,
                    embedding_provider_name = EXCLUDED.embedding_provider_name, embedding_model_name = EXCLUDED.embedding_model_name,
                    updated_by = EXCLUDED.updated_by, updated_at = now()
                """, logger: self.logger)
        }
    }

    /// Dify's disable job: removes the setting.
    public func disableAnnotationReply(_ doc: String) async throws {
        try await bounded { _ = try await self.client.query("DELETE FROM app_annotation_settings WHERE doc_id = \(doc)", logger: self.logger) }
    }

    /// Dify's `update_app_annotation_setting`. nil if the app has no setting with that id.
    public func updateAnnotationScore(_ doc: String, settingId: String, scoreThreshold: Double, by: String) async throws -> StoredAnnotationSetting? {
        try await bounded {
            for try await r in try await self.client.query("""
                UPDATE app_annotation_settings SET score_threshold = \(scoreThreshold), updated_by = \(by), updated_at = now()
                WHERE doc_id = \(doc) AND id = \(settingId)
                RETURNING id, score_threshold, embedding_provider_name, embedding_model_name
                """, logger: self.logger).decode((String, Double, String, String).self) {
                return StoredAnnotationSetting(id: r.0, scoreThreshold: r.1, embeddingProviderName: r.2, embeddingModelName: r.3)
            }
            return nil
        }
    }

    // MARK: - Jobs

    /// Records job `id` of `kind` (`import`, `enable`, `disable`) for app `doc` (and forgets expired jobs).
    public func recordJob(_ id: String, doc: String, kind: String, status: String, error: String = "") async throws {
        try await bounded {
            let ttl = "\(Self.jobSeconds) seconds"
            _ = try await self.client.query("DELETE FROM app_jobs WHERE created_at < now() - \(ttl)::interval", logger: self.logger)
            _ = try await self.client.query("""
                INSERT INTO app_jobs (id, doc_id, kind, status, error) VALUES (\(id), \(doc), \(kind), \(status), \(error))
                """, logger: self.logger)
        }
    }

    /// The state and error of job `id` of `kind` for app `doc`; nil if unknown or expired.
    public func job(_ id: String, doc: String, kind: String) async throws -> (status: String, error: String)? {
        try await bounded {
            let ttl = "\(Self.jobSeconds) seconds"
            for try await (s, e) in try await self.client.query("""
                SELECT status, error FROM app_jobs WHERE id = \(id) AND doc_id = \(doc) AND kind = \(kind)
                  AND created_at >= now() - \(ttl)::interval
                """, logger: self.logger).decode((String, String).self) { return (s, e) }
            return nil
        }
    }

    // MARK: - Message feedback

    /// A member's feedback on message `message` of app `doc` (Dify's `_update_message_feedback`): no rating removes the
    /// admin feedback, a rating replaces its rating and content (or creates it, by `account`). One transaction; the message
    /// row is locked, so concurrent calls on one message apply one after the other.
    public func setAdminFeedback(_ doc: String, message: UUID, rating: String?, content: String?, account: String) async throws -> AdminFeedbackOutcome {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { tx in
                var conversation: UUID?
                for try await c in try await tx.query("""
                    SELECT conversation_id FROM app_messages WHERE id = \(message) AND doc_id = \(doc) FOR UPDATE
                    """, logger: self.logger).decode(UUID.self) { conversation = c }
                guard let conversation else { return .noMessage }
                var existing: UUID?
                for try await id in try await tx.query("""
                    SELECT id FROM app_message_feedbacks WHERE message_id = \(message) AND from_source = 'admin'
                    """, logger: self.logger).decode(UUID.self) { existing = id }
                switch (rating, existing) {
                case (nil, let id?):
                    _ = try await tx.query("DELETE FROM app_message_feedbacks WHERE id = \(id)", logger: self.logger)
                    return .deleted
                case (let r?, let id?):
                    _ = try await tx.query("""
                        UPDATE app_message_feedbacks SET rating = \(r), content = \(content), updated_at = clock_timestamp() WHERE id = \(id)
                        """, logger: self.logger)
                    return .updated
                case (nil, nil):
                    return .nothingToClear
                case (let r?, nil):
                    _ = try await tx.query("""
                        INSERT INTO app_message_feedbacks (id, doc_id, conversation_id, message_id, rating, content, from_source, from_account_id)
                        VALUES (\(UUID()), \(doc), \(conversation), \(message), \(r), \(content), 'admin', \(account))
                        """, logger: self.logger)
                    return .created
                }
            }
        }
    }

    // MARK: - Versions

    static let versionColumnsSQL = """
        v.id, v.version_number::bigint, v.version, v.seq, v.state::text, v.dsl::text, v.hash, v.marked_name, v.marked_comment,
        v.created_by, cb.name, cb.email, v.created_at, v.updated_by, ub.name, ub.email, v.updated_at
        """
    static let versionJoinSQL = "LEFT JOIN accounts cb ON cb.id = v.created_by LEFT JOIN accounts ub ON ub.id = v.updated_by"

    func decodeVersions(_ rows: PostgresRowSequence) async throws -> [StoredVersion] {
        var out: [StoredVersion] = []
        for try await r in rows.decode((String, Int, String, Int, String, String, String, String, String, String?, String?, String?, Date,
                                        String?, String?, String?, Date).self) {
            func account(_ id: String?, _ name: String?, _ email: String?) -> StoredVersion.Account? {
                id.map { StoredVersion.Account(id: $0, name: name ?? $0, email: email ?? "") }
            }
            out.append(StoredVersion(id: r.0, number: r.1, version: r.2, seq: r.3, state: r.4, dsl: r.5, hash: r.6, markedName: r.7,
                                     markedComment: r.8, createdBy: account(r.9, r.10, r.11), createdAt: r.12,
                                     updatedBy: account(r.13, r.14, r.15), updatedAt: r.16))
        }
        return out
    }

    /// Stores a new version of app `doc` (the next version number; Dify's `version`: the UTC time as `str(datetime)`) and
    /// bumps the app's `updated_at` (Dify's publish sets `app.updated_at`). nil for an unknown or deleted app.
    public func publishVersion(_ doc: String, id: String, seq: Int, state: String, dsl: String, hash: String, markedName: String,
                               markedComment: String, by: String) async throws -> StoredVersion? {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { tx in
                var number: Int?
                for try await n in try await tx.query("""
                    UPDATE apps SET last_version_number = last_version_number + 1, updated_by = \(by), updated_at = now()
                    WHERE doc_id = \(doc) AND deleted_at IS NULL RETURNING last_version_number::bigint
                    """, logger: self.logger).decode(Int.self) { number = n }
                guard let number else { return nil }
                _ = try await tx.query("""
                    WITH t AS (SELECT clock_timestamp() AS ts)
                    INSERT INTO app_versions (id, doc_id, version_number, version, seq, state, dsl, hash, marked_name, marked_comment,
                                              created_by, created_at, updated_by, updated_at)
                    SELECT \(id), \(doc), \(number), regexp_replace(to_char(t.ts AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US'), '\\.000000$', ''),
                           \(seq), \(state)::text::jsonb, \(dsl)::text::jsonb, \(hash), \(markedName), \(markedComment), \(by), t.ts, \(by), t.ts
                    FROM t
                    """, logger: self.logger)
                try await self.publishAgentBindings(doc: doc, version: id, state: state, tx: tx)
                return try await self.decodeVersions(try await tx.query("""
                    SELECT \(unescaped: Self.versionColumnsSQL) FROM app_versions v \(unescaped: Self.versionJoinSQL) WHERE v.id = \(id)
                    """, logger: self.logger)).first
            }
        }
    }

    /// App `doc`'s versions newest first (`offset`, at most `limit`), optionally only those `createdBy` made or only named
    /// ones.
    public func versions(_ doc: String, offset: Int, limit: Int, createdBy: String?, namedOnly: Bool) async throws -> [StoredVersion] {
        try await bounded {
            try await self.decodeVersions(try await self.client.query("""
                SELECT \(unescaped: Self.versionColumnsSQL) FROM app_versions v \(unescaped: Self.versionJoinSQL)
                WHERE v.doc_id = \(doc) AND (\(createdBy)::text IS NULL OR v.created_by = \(createdBy))
                  AND (NOT \(namedOnly) OR v.marked_name <> '')
                ORDER BY v.created_at DESC, v.id DESC LIMIT \(unescaped: String(max(0, limit))) OFFSET \(unescaped: String(max(0, offset)))
                """, logger: self.logger))
        }
    }

    /// The published (newest) version of app `doc`, nil if it was never published.
    public func latestVersion(_ doc: String) async throws -> StoredVersion? {
        try await versions(doc, offset: 0, limit: 1, createdBy: nil, namedOnly: false).first
    }

    public func version(_ doc: String, id: String) async throws -> StoredVersion? {
        try await bounded {
            try await self.decodeVersions(try await self.client.query("""
                SELECT \(unescaped: Self.versionColumnsSQL) FROM app_versions v \(unescaped: Self.versionJoinSQL)
                WHERE v.doc_id = \(doc) AND v.id = \(id)
                """, logger: self.logger)).first
        }
    }

    /// Renames / re-comments a version (nil members keep their value). nil if there is no such version.
    public func updateVersion(_ doc: String, id: String, markedName: String?, markedComment: String?, by: String) async throws -> StoredVersion? {
        try await bounded {
            var found = false
            for try await _ in try await self.client.query("""
                UPDATE app_versions SET marked_name = COALESCE(\(markedName), marked_name),
                       marked_comment = COALESCE(\(markedComment), marked_comment), updated_by = \(by), updated_at = clock_timestamp()
                WHERE doc_id = \(doc) AND id = \(id) RETURNING 1
                """, logger: self.logger) { found = true }
            guard found else { return nil }
            return try await self.decodeVersions(try await self.client.query("""
                SELECT \(unescaped: Self.versionColumnsSQL) FROM app_versions v \(unescaped: Self.versionJoinSQL) WHERE v.id = \(id)
                """, logger: self.logger)).first
        }
    }

    /// Deletes a version unless it is the published (newest) one.
    public func deleteVersion(_ doc: String, id: String) async throws -> VersionDeletion {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { tx in
                for try await _ in try await tx.query("SELECT 1 FROM apps WHERE doc_id = \(doc) FOR UPDATE", logger: self.logger) {}
                var exists = false
                for try await _ in try await tx.query("SELECT 1 FROM app_versions WHERE doc_id = \(doc) AND id = \(id)", logger: self.logger) {
                    exists = true
                }
                guard exists else { return .missing }
                for try await latest in try await tx.query("""
                    SELECT id FROM app_versions WHERE doc_id = \(doc) ORDER BY created_at DESC, id DESC LIMIT 1
                    """, logger: self.logger).decode(String.self) where latest == id { return .inUse }
                _ = try await tx.query("DELETE FROM app_versions WHERE doc_id = \(doc) AND id = \(id)", logger: self.logger)
                return .deleted
            }
        }
    }
}
