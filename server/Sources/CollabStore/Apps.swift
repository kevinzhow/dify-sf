import CollabCore
import Foundation
import PostgresNIO

/// The app row of a new document (protocol 1.10): what Dify keeps in its `apps` table. Every document gets exactly one, in
/// the transaction that creates it.
public struct NewApp: Sendable, Equatable {
    public var name: String
    public var description: String
    public var mode: String
    public var iconType: String?
    public var icon: String?
    public var iconBackground: String?
    public var useIconAsAnswerIcon: Bool
    public var maxActiveRequests: Int?
    /// Account id; nil = unknown (documents created without an account, e.g. by the harnesses).
    public var createdBy: String?

    public init(name: String, description: String = "", mode: String = "workflow", iconType: String? = NewApp.defaultIconType,
                icon: String? = NewApp.defaultIcon, iconBackground: String? = NewApp.defaultIconBackground,
                useIconAsAnswerIcon: Bool = false, maxActiveRequests: Int? = nil, createdBy: String? = nil) {
        self.name = name
        self.description = description
        self.mode = mode
        self.iconType = iconType
        self.icon = icon
        self.iconBackground = iconBackground
        self.useIconAsAnswerIcon = useIconAsAnswerIcon
        self.maxActiveRequests = maxActiveRequests
        self.createdBy = createdBy
    }

    /// Dify's defaults (`DifyDSL.defaultMetadata`): an emoji robot on Dify's orange.
    public static let defaultIconType = "emoji"
    public static let defaultIcon = "🤖"
    public static let defaultIconBackground = "#FFEAD5"

    /// The row of a document whose Dify metadata is `metadata` (its `app` section; the migration's rules): name from the
    /// file, else `fallbackName`; mode, description and icon from the file, else Dify's defaults.
    public static func from(metadata: Value?, fallbackName: String, createdBy: String?) -> NewApp {
        var app: [String: Value] = [:]
        if case .map(let top)? = metadata, case .map(let a)? = top["app"] { app = a }
        func str(_ k: String) -> String? { if case .string(let s)? = app[k], !s.isEmpty { return s }; return nil }
        let iconType = str("icon_type").flatMap { ["emoji", "image", "link"].contains($0) ? $0 : nil } ?? defaultIconType
        return NewApp(name: str("name") ?? fallbackName, description: str("description") ?? "", mode: str("mode") ?? "workflow",
                      iconType: iconType, icon: str("icon") ?? defaultIcon, iconBackground: str("icon_background") ?? defaultIconBackground,
                      useIconAsAnswerIcon: app["use_icon_as_answer_icon"] == .bool(true), createdBy: createdBy)
    }
}

/// An app as read (Dify's `AppPartial` / `AppDetail` members dify-sf has).
public struct StoredApp: Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String
    public var mode: String
    public var iconType: String?
    public var icon: String?
    public var iconBackground: String?
    public var useIconAsAnswerIcon: Bool
    public var maxActiveRequests: Int?
    /// The creator (for apps of unknown origin: the workspace owner).
    public var createdBy: String?
    public var createdAt: Date
    public var updatedBy: String?
    /// "Last modified": the later of the app row's change and the document's last commit (protocol 1.10's deviation from
    /// Dify, which bumps it on app-row changes only).
    public var updatedAt: Date
    /// The creator's account name.
    public var authorName: String?
    /// Starred by the account the read was made for.
    public var isStarred: Bool
    public var deleted: Bool
    /// Protocol 1.11: the Web App and Service API switches.
    public var enableSite: Bool = true
    public var enableApi: Bool = true
    /// Protocol 1.11: the Web App site as JSON text (`PostgresStore.siteJSONSQL`), nil if the app has none.
    public var siteJSON: String?
}

/// `GET /v1/apps` and `/v1/apps/starred` filters (Dify's `AppListParams`).
public struct AppListQuery: Sendable, Equatable {
    public enum Sort: String, Sendable, CaseIterable {
        case lastModified = "last_modified"
        case recentlyCreated = "recently_created"
        case earliestCreated = "earliest_created"
    }

    /// 1-based.
    public var page: Int
    public var limit: Int
    /// nil = every mode.
    public var mode: String?
    /// Case-insensitive substring of the name.
    public var name: String?
    public var sort: Sort
    /// Apps created by any of these accounts (empty = anyone).
    public var creatorIds: [String]
    /// Apps created by this account only (Dify's `is_created_by_me`).
    public var createdBy: String?
    /// Only apps this account starred.
    public var starredBy: String?

    public init(page: Int = 1, limit: Int = 20, mode: String? = nil, name: String? = nil, sort: Sort = .lastModified,
                creatorIds: [String] = [], createdBy: String? = nil, starredBy: String? = nil) {
        self.page = page
        self.limit = limit
        self.mode = mode
        self.name = name
        self.sort = sort
        self.creatorIds = creatorIds
        self.createdBy = createdBy
        self.starredBy = starredBy
    }
}

/// Whether a document id names a document, and whether its app was deleted.
public enum DocumentStatus: Sendable, Equatable {
    case live(head: Int)
    case deleted
}

/// A Dify DSL import waiting for the user's confirmation of its version (Dify's `PendingData` in Redis, 10 minutes).
public struct PendingImport: Sendable, Equatable {
    public var yaml: String
    /// The request's `name`, `description`, `icon_type`, `icon`, `icon_background` (JSON object text).
    public var overrides: String

    public init(yaml: String, overrides: String) {
        self.yaml = yaml
        self.overrides = overrides
    }
}

/// Apps (protocol 1.10, Dify's Studio): one row per document in `apps` (soft-deleted with `deleted_at`), stars per account
/// in `app_stars`, pending imports in `app_imports`. Every operation is bounded by `operationTimeout`.
extension PostgresStore {
    /// How long a pending import waits for its confirmation (Dify's `IMPORT_INFO_REDIS_EXPIRY`, 10 minutes).
    public static let pendingImportSeconds = 600

    /// The creator as read: the stored one, else the workspace owner (documents of unknown origin, such as those created
    /// before accounts existed).
    static let creatorSQL = "COALESCE(a.created_by, (SELECT m.account_id FROM members m WHERE m.role = 'owner' LIMIT 1))"

    // MARK: - Reads

    public func documentStatus(_ id: String) async throws -> DocumentStatus? {
        try await bounded {
            let rows = try await self.client.query("""
                SELECT d.head, a.deleted_at IS NOT NULL FROM documents d LEFT JOIN apps a ON a.doc_id = d.id WHERE d.id = \(id)
                """, logger: self.logger)
            for try await (head, deleted) in rows.decode((Int, Bool).self) { return deleted ? .deleted : .live(head: head) }
            return nil
        }
    }

    /// One page of the live apps matching `q`, and how many match in all. `viewer` decides `isStarred`.
    public func listApps(_ q: AppListQuery, viewer: String) async throws -> (total: Int, apps: [StoredApp]) {
        try await bounded {
            let order: String
            switch q.sort {
            case .lastModified: order = "modified DESC, a.doc_id"
            case .recentlyCreated: order = "a.created_at DESC, a.doc_id"
            case .earliestCreated: order = "a.created_at, a.doc_id"
            }
            let creators = q.creatorIds, mode = q.mode, name = q.name, mine = q.createdBy, starred = q.starredBy
            let offset = max(0, (q.page - 1) * q.limit), limit = max(0, q.limit)
            var total = 0
            let count: PostgresQuery = """
                SELECT count(*)::bigint FROM apps a
                WHERE a.deleted_at IS NULL
                  AND (\(mode)::text IS NULL OR a.mode = \(mode))
                  AND (\(name)::text IS NULL OR strpos(lower(a.name), lower(\(name))) > 0)
                  AND (cardinality(\(creators)::text[]) = 0 OR \(unescaped: Self.creatorSQL) = ANY(\(creators)::text[]))
                  AND (\(mine)::text IS NULL OR \(unescaped: Self.creatorSQL) = \(mine))
                  AND (\(starred)::text IS NULL
                       OR EXISTS (SELECT 1 FROM app_stars s WHERE s.doc_id = a.doc_id AND s.account_id = \(starred)))
                """
            for try await n in try await self.client.query(count, logger: self.logger).decode(Int.self) { total = n }
            let list: PostgresQuery = """
                SELECT \(unescaped: Self.columnsSQL),
                       EXISTS (SELECT 1 FROM app_stars s WHERE s.doc_id = a.doc_id AND s.account_id = \(viewer))
                FROM apps a JOIN documents d ON d.id = a.doc_id
                WHERE a.deleted_at IS NULL
                  AND (\(mode)::text IS NULL OR a.mode = \(mode))
                  AND (\(name)::text IS NULL OR strpos(lower(a.name), lower(\(name))) > 0)
                  AND (cardinality(\(creators)::text[]) = 0 OR \(unescaped: Self.creatorSQL) = ANY(\(creators)::text[]))
                  AND (\(mine)::text IS NULL OR \(unescaped: Self.creatorSQL) = \(mine))
                  AND (\(starred)::text IS NULL
                       OR EXISTS (SELECT 1 FROM app_stars s WHERE s.doc_id = a.doc_id AND s.account_id = \(starred)))
                ORDER BY \(unescaped: order)
                LIMIT \(unescaped: String(limit)) OFFSET \(unescaped: String(offset))
                """
            let apps = try await self.decodeApps(try await self.client.query(list, logger: self.logger))
            return (total, apps)
        }
    }

    /// App `id` as `viewer` sees it, deleted or not; nil for an unknown document.
    public func app(_ id: String, viewer: String) async throws -> StoredApp? {
        try await bounded {
            let q: PostgresQuery = """
                SELECT \(unescaped: Self.columnsSQL),
                       EXISTS (SELECT 1 FROM app_stars s WHERE s.doc_id = a.doc_id AND s.account_id = \(viewer))
                FROM apps a JOIN documents d ON d.id = a.doc_id WHERE a.doc_id = \(id)
                """
            return try await self.decodeApps(try await self.client.query(q, logger: self.logger)).first
        }
    }

    /// The selected columns, in `decodeApps`' order (the viewer's star follows them). `modified` is "last modified".
    static let columnsSQL = """
        a.doc_id, a.name, a.description, a.mode, a.icon_type, a.icon, a.icon_background, a.use_icon_as_answer_icon,
        a.max_active_requests::bigint, \(creatorSQL), a.created_at, a.updated_by,
        (SELECT acc.name FROM accounts acc WHERE acc.id = \(creatorSQL)),
        a.deleted_at IS NOT NULL, GREATEST(a.updated_at, d.updated_at) AS modified, a.enable_site, a.enable_api,
        \(siteJSONSQL)
        """

    func decodeApps(_ rows: PostgresRowSequence) async throws -> [StoredApp] {
        var out: [StoredApp] = []
        for try await r in rows.decode((String, String, String, String, String?, String?, String?, Bool, Int?, String?, Date, String?,
                                        String?, Bool, Date, Bool, Bool, String?, Bool).self) {
            out.append(StoredApp(id: r.0, name: r.1, description: r.2, mode: r.3, iconType: r.4, icon: r.5, iconBackground: r.6,
                                 useIconAsAnswerIcon: r.7, maxActiveRequests: r.8, createdBy: r.9, createdAt: r.10, updatedBy: r.11,
                                 updatedAt: r.14, authorName: r.12, isStarred: r.18, deleted: r.13, enableSite: r.15, enableApi: r.16,
                                 siteJSON: r.17))
        }
        return out
    }

    // MARK: - Writes

    /// Edit info (Dify's `PUT /apps/{id}`): nil members keep their value. Returns false for an unknown or deleted app.
    public func updateApp(_ id: String, name: String?, description: String?, iconType: String?, icon: String?, iconBackground: String?,
                          useIconAsAnswerIcon: Bool?, maxActiveRequests: Int?, by: String?) async throws -> Bool {
        try await bounded {
            let mar = maxActiveRequests.map { Int64($0) }
            let rows = try await self.client.query("""
                UPDATE apps SET name = COALESCE(\(name), name), description = COALESCE(\(description), description),
                       icon_type = COALESCE(\(iconType), icon_type), icon = COALESCE(\(icon), icon),
                       icon_background = COALESCE(\(iconBackground), icon_background),
                       use_icon_as_answer_icon = COALESCE(\(useIconAsAnswerIcon), use_icon_as_answer_icon),
                       max_active_requests = COALESCE(\(mar)::bigint, max_active_requests::bigint)::integer,
                       updated_by = COALESCE(\(by), updated_by), updated_at = now()
                WHERE doc_id = \(id) AND deleted_at IS NULL RETURNING 1
                """, logger: self.logger)
            for try await _ in rows { return true }
            return false
        }
    }

    /// Soft delete: the app leaves every list and its document answers as deleted. The document row's revision is bumped
    /// in the same transaction, so a sequencer of any process that still holds the document fails its next commit's
    /// revision check, reloads and finds it deleted. Returns false for an unknown or already deleted app.
    public func deleteApp(_ id: String) async throws -> Bool {
        try await bounded {
            try await self.client.withTransaction(logger: self.logger) { tx in
                var exists = false
                for try await _ in try await tx.query("SELECT rev FROM documents WHERE id = \(id) FOR UPDATE", logger: self.logger) { exists = true }
                guard exists else { return false }
                var deleted = false
                for try await _ in try await tx.query(
                    "UPDATE apps SET deleted_at = now() WHERE doc_id = \(id) AND deleted_at IS NULL RETURNING 1", logger: self.logger
                ) { deleted = true }
                if deleted { _ = try await tx.query("UPDATE documents SET rev = rev + 1 WHERE id = \(id)", logger: self.logger) }
                return deleted
            }
        }
    }

    /// Stars app `id` for `account` (idempotent). False for an unknown or deleted app.
    public func starApp(_ id: String, account: String) async throws -> Bool {
        try await bounded {
            let rows = try await self.client.query("""
                WITH live AS (SELECT doc_id FROM apps WHERE doc_id = \(id) AND deleted_at IS NULL),
                     ins AS (INSERT INTO app_stars (account_id, doc_id) SELECT \(account), doc_id FROM live ON CONFLICT DO NOTHING)
                SELECT 1 FROM live
                """, logger: self.logger)
            for try await _ in rows { return true }
            return false
        }
    }

    /// Removes `account`'s star (idempotent). False for an unknown or deleted app.
    public func unstarApp(_ id: String, account: String) async throws -> Bool {
        try await bounded {
            let rows = try await self.client.query("""
                WITH live AS (SELECT doc_id FROM apps WHERE doc_id = \(id) AND deleted_at IS NULL),
                     del AS (DELETE FROM app_stars WHERE account_id = \(account) AND doc_id IN (SELECT doc_id FROM live))
                SELECT 1 FROM live
                """, logger: self.logger)
            for try await _ in rows { return true }
            return false
        }
    }

    /// How many secret rows document `id` has (sealed or not).
    public func secretCount(_ id: String) async throws -> Int {
        try await bounded {
            for try await n in try await self.client.query("SELECT count(*)::bigint FROM secrets WHERE doc_id = \(id)", logger: self.logger)
                .decode(Int.self) { return n }
            return 0
        }
    }

    // MARK: - Pending imports

    /// Stores an import that waits for confirmation (and forgets expired ones).
    public func storePendingImport(_ id: String, account: String, _ p: PendingImport) async throws {
        try await bounded {
            let ttl = "\(Self.pendingImportSeconds) seconds"
            _ = try await self.client.query(
                "DELETE FROM app_imports WHERE created_at < now() - \(ttl)::interval", logger: self.logger)
            _ = try await self.client.query("""
                INSERT INTO app_imports (id, account_id, yaml, overrides) VALUES (\(id), \(account), \(p.yaml), \(p.overrides)::text::jsonb)
                """, logger: self.logger)
        }
    }

    /// Takes (removes and returns) `account`'s pending import `id`; nil if there is none, it expired or is someone else's.
    public func takePendingImport(_ id: String, account: String) async throws -> PendingImport? {
        try await bounded {
            let ttl = "\(Self.pendingImportSeconds) seconds"
            let rows = try await self.client.query("""
                DELETE FROM app_imports WHERE id = \(id) AND account_id = \(account)
                RETURNING yaml, overrides::text, created_at >= now() - \(ttl)::interval
                """, logger: self.logger)
            for try await (yaml, overrides, fresh) in rows.decode((String, String, Bool).self) {
                return fresh ? PendingImport(yaml: yaml, overrides: overrides) : nil
            }
            return nil
        }
    }

    // MARK: - Migration

    /// Protocol 1.10 migration: gives every document without an app row one (idempotent; run at startup). Name, mode,
    /// description and icon from the imported file's `app` section, else the document id and Dify's defaults; the creator is
    /// the account of the document's earliest client id (NULL if none: read as the workspace owner); created at the
    /// document's creation, last modified at its last commit. Returns the number of rows added.
    @discardableResult
    public func backfillApps() async throws -> Int {
        try await bounded {
            let rows = try await self.client.query("""
                INSERT INTO apps (doc_id, name, description, mode, icon_type, icon, icon_background, use_icon_as_answer_icon,
                                  created_by, created_at, updated_at)
                SELECT d.id,
                       COALESCE(NULLIF(m.dsl->'app'->>'name', ''), d.id),
                       COALESCE(m.dsl->'app'->>'description', ''),
                       COALESCE(NULLIF(m.dsl->'app'->>'mode', ''), 'workflow'),
                       CASE WHEN m.dsl->'app'->>'icon_type' IN ('emoji', 'image', 'link') THEN m.dsl->'app'->>'icon_type' ELSE 'emoji' END,
                       COALESCE(NULLIF(m.dsl->'app'->>'icon', ''), \(NewApp.defaultIcon)),
                       COALESCE(NULLIF(m.dsl->'app'->>'icon_background', ''), \(NewApp.defaultIconBackground)),
                       COALESCE(m.dsl->'app'->'use_icon_as_answer_icon' = 'true'::jsonb, false),
                       (SELECT ca.account_id FROM client_accounts ca WHERE ca.doc_id = d.id ORDER BY ca.created_at, ca.client_id LIMIT 1),
                       d.created_at,
                       COALESCE((SELECT max(o.committed_at) FROM ops o WHERE o.doc_id = d.id), d.created_at)
                FROM documents d LEFT JOIN doc_meta m ON m.doc_id = d.id
                WHERE NOT EXISTS (SELECT 1 FROM apps a WHERE a.doc_id = d.id)
                ON CONFLICT (doc_id) DO NOTHING
                RETURNING doc_id
                """, logger: self.logger)
            var n = 0
            for try await _ in rows { n += 1 }
            return n
        }
    }

    /// Inserts the app row of a document created in transaction `tx`.
    func insertApp(_ tx: PostgresConnection, id: String, _ a: NewApp) async throws {
        let mar = a.maxActiveRequests.map { Int64($0) }
        _ = try await tx.query("""
            INSERT INTO apps (doc_id, name, description, mode, icon_type, icon, icon_background, use_icon_as_answer_icon,
                              max_active_requests, created_by, updated_by)
            VALUES (\(id), \(a.name), \(a.description), \(a.mode), \(a.iconType), \(a.icon), \(a.iconBackground), \(a.useIconAsAnswerIcon),
                    \(mar)::bigint::integer, \(a.createdBy), \(a.createdBy))
            """, logger: logger)
        // Protocol 1.11: every app has a Web App site from its creation (Dify's `app_was_created` handler).
        try await insertSite(tx, id: id, name: a.name, iconType: a.iconType, icon: a.icon, iconBackground: a.iconBackground,
                             createdBy: a.createdBy)
    }
}
