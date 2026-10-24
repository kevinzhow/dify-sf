// Dify workflow/app statistic queries: durable published root runs only.
import Foundation
import PostgresNIO

public struct PublishedDayMetric: Sendable {
    public var date: String
    public var runs, users, tokens, messages, conversations, likes: Int
    public var interactions, sessionInteractions, latency, tps: Double
    public var price: String?
    public var currency: String?
}
public struct PublishedLogFilter: Sendable {
    public var page = 1, limit = 20
    public var status: String?, keyword: String?, source: String?, endUser: String?
    public var start: Date?, end: Date?
    public init() {}
}
public struct PublishedRunLog: Sendable {
    public var run: StoredWorkflowRun
    public var user: StoredEndUser
}

extension PostgresStore {
    public func publishedRunPage(app: String, filter f: PublishedLogFilter) async throws -> (Int, [PublishedRunLog]) {
        try await bounded {
            var total = 0
            let keyword = f.keyword.flatMap { $0.isEmpty ? nil : $0.lowercased() }
            func q(_ count: Bool) -> PostgresQuery {
                let select = count ? "count(*)::bigint" : Self.runColumns + ", e.source, e.namespace, e.external_id, e.created_at"
                let order = count ? "" : "ORDER BY r.created_at DESC, r.id DESC LIMIT \(f.limit) OFFSET \((f.page - 1) * f.limit)"
                return """
                    SELECT \(unescaped: select) FROM workflow_runs r
                    JOIN app_end_users e ON e.id = r.end_user_id LEFT JOIN accounts a ON a.id = r.created_by
                    WHERE r.doc_id = \(app) AND r.triggered_from = 'app-run'
                      AND (\(f.status)::text IS NULL OR r.status = \(f.status))
                      AND (\(f.source)::text IS NULL OR e.source = \(f.source))
                      AND (\(f.endUser)::text IS NULL OR e.id = \(f.endUser) OR e.external_id = \(f.endUser))
                      AND (\(f.start)::timestamptz IS NULL OR r.created_at >= \(f.start))
                      AND (\(f.end)::timestamptz IS NULL OR r.created_at < \(f.end))
                      AND (\(keyword)::text IS NULL OR strpos(lower(r.id || ' ' || r.inputs || ' ' || e.external_id), \(keyword)) > 0)
                    \(unescaped: order)
                    """
            }
            for try await count in try await self.client.query(q(true), logger: self.logger).decode(Int64.self) { total = Int(count) }
            var values: [PublishedRunLog] = []
            for try await row in try await self.client.query(q(false), logger: self.logger) {
                let r = row.makeRandomAccess(), run = try Self.decodeRun(row)
                values.append(PublishedRunLog(run: run, user: StoredEndUser(id: run.endUserId!, appId: app,
                    source: try r[25].decode(String.self), namespace: try r[26].decode(String.self), externalId: try r[27].decode(String.self),
                    createdAt: try r[28].decode(Date.self))))
            }
            return (total, values)
        }
    }

    public func publishedMetrics(app: String, start: Date?, end: Date?, timezone: String) async throws -> [PublishedDayMetric] {
        try await bounded {
            var values: [PublishedDayMetric] = []
            for try await row in try await self.client.query("""
                SELECT to_char(r.created_at AT TIME ZONE \(timezone), 'YYYY-MM-DD') AS day,
                    count(*)::bigint, count(DISTINCT r.end_user_id)::bigint, COALESCE(sum(r.total_tokens),0)::bigint,
                    count(m.id)::bigint, count(DISTINCT m.conversation_id)::bigint,
                    count(*) FILTER (WHERE EXISTS (SELECT 1 FROM app_message_feedbacks f WHERE f.message_id=m.id AND f.rating='like'))::bigint,
                    count(*)::double precision / NULLIF(count(DISTINCT r.end_user_id),0),
                    COALESCE(count(m.id)::double precision / NULLIF(count(DISTINCT m.conversation_id),0),0),
                    COALESCE(avg((m.metadata::jsonb->'usage'->>'latency')::double precision),0)::double precision,
                    COALESCE(sum((m.metadata::jsonb->'usage'->>'completion_tokens')::double precision) /
                        NULLIF(sum((m.metadata::jsonb->'usage'->>'latency')::double precision),0),0)::double precision,
                    CASE WHEN count(DISTINCT m.metadata::jsonb->'usage'->>'currency')=1
                        THEN sum((m.metadata::jsonb->'usage'->>'total_price')::numeric)::text ELSE NULL END,
                    CASE WHEN count(DISTINCT m.metadata::jsonb->'usage'->>'currency')=1
                        THEN min(m.metadata::jsonb->'usage'->>'currency') ELSE NULL END
                FROM workflow_runs r LEFT JOIN app_messages m ON m.workflow_run_id=r.id AND m.end_user_id=r.end_user_id
                WHERE r.doc_id=\(app) AND r.triggered_from='app-run' AND r.end_user_id IS NOT NULL
                    AND (\(start)::timestamptz IS NULL OR r.created_at>=\(start))
                    AND (\(end)::timestamptz IS NULL OR r.created_at<\(end))
                GROUP BY day ORDER BY day
                """, logger: self.logger) {
                let r = row.makeRandomAccess()
                values.append(PublishedDayMetric(date: try r[0].decode(String.self), runs: Int(try r[1].decode(Int64.self)),
                    users: Int(try r[2].decode(Int64.self)), tokens: Int(try r[3].decode(Int64.self)), messages: Int(try r[4].decode(Int64.self)),
                    conversations: Int(try r[5].decode(Int64.self)), likes: Int(try r[6].decode(Int64.self)), interactions: try r[7].decode(Double.self),
                    sessionInteractions: try r[8].decode(Double.self), latency: try r[9].decode(Double.self), tps: try r[10].decode(Double.self),
                    price: try r[11].decode(String?.self), currency: try r[12].decode(String?.self)))
            }
            return values
        }
    }

    /// Monitoring explicitly authorizes a published conversation. Console debugger
    /// APIs continue to use chatConversation(account:, endUser:nil).
    public func publishedConversation(app: String, id: String) async throws -> StoredChatConversation? {
        guard let id = UUID(uuidString: id) else { return nil }
        return try await bounded {
            for try await row in try await self.client.query("""
                SELECT \(unescaped: Self.chatConversationColumns) FROM app_chat_conversations
                WHERE doc_id=\(app) AND id=\(id) AND end_user_id IS NOT NULL
                """, logger: self.logger) { return try Self.decodeChatConversation(row) }
            return nil
        }
    }
    public func publishedConversationPage(app: String, page: Int, limit: Int, keyword: String?, start: Date?, end: Date?, sort: String) async throws -> (Int, [StoredChatConversation]) {
        try await bounded {
            let order = ["created_at", "-created_at", "updated_at", "-updated_at"].contains(sort) ? sort : "-updated_at"
            let column = order.hasPrefix("-") ? String(order.dropFirst()) : order
            let direction = order.hasPrefix("-") ? "DESC" : "ASC"
            let keyword = keyword.flatMap { $0.isEmpty ? nil : $0.lowercased() }
            func q(_ count: Bool) -> PostgresQuery {
                let select = count ? "count(*)::bigint" : Self.chatConversationColumns.split(separator: ",").map { "c." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ",")
                let suffix = count ? "" : "ORDER BY c.\(column) \(direction), c.id LIMIT \(limit) OFFSET \((page-1)*limit)"
                return """
                    SELECT \(unescaped: select) FROM app_chat_conversations c
                    WHERE c.doc_id=\(app) AND c.end_user_id IS NOT NULL
                      AND (\(start)::timestamptz IS NULL OR c.created_at>=\(start))
                      AND (\(end)::timestamptz IS NULL OR c.created_at<\(end))
                      AND (\(keyword)::text IS NULL OR EXISTS (SELECT 1 FROM app_messages m WHERE m.conversation_id=c.id
                          AND strpos(lower(m.query || ' ' || m.answer),\(keyword))>0))
                    \(unescaped: suffix)
                    """
            }
            var total=0, values:[StoredChatConversation]=[]
            for try await n in try await self.client.query(q(true), logger:self.logger).decode(Int64.self) { total=Int(n) }
            for try await row in try await self.client.query(q(false), logger:self.logger) { values.append(try Self.decodeChatConversation(row)) }
            return(total,values)
        }
    }
}

extension PostgresStore {
    public func conversationFeedbackStats(app: String, conversation: String) async throws -> [(source: String, rating: String, count: Int)] {
        guard let id=UUID(uuidString:conversation) else { return [] }
        return try await bounded {
            var result:[(String,String,Int)]=[]
            for try await row in try await self.client.query("""
                SELECT from_source,rating,count(*)::bigint FROM app_message_feedbacks
                WHERE doc_id=\(app) AND conversation_id=\(id) GROUP BY from_source,rating
                """,logger:self.logger).decode((String,String,Int64).self) { result.append((row.0,row.1,Int(row.2))) }
            return result
        }
    }
}


extension PostgresStore {
    public func publicMessage(app:String,conversation:String,endUser:String,message:String) async throws -> StoredChatMessage? {
        guard let cid=UUID(uuidString:conversation),let mid=UUID(uuidString:message) else { return nil }
        return try await bounded {
            for try await row in try await self.client.query("""
                SELECT \(unescaped:Self.chatMessageColumns) FROM app_messages
                WHERE doc_id=\(app) AND conversation_id=\(cid) AND id=\(mid) AND end_user_id=\(endUser)
                """,logger:self.logger) { return try Self.decodeChatMessage(row) }
            return nil
        }
    }
    public func conversationSummary(app:String,conversation:String) async throws -> (count:Int,title:String,statuses:[String:Int]) {
        guard let cid=UUID(uuidString:conversation) else { throw ChatStoreError.notFound }
        return try await bounded {
            var count=0,title="",statuses:[String:Int]=[:]
            for try await row in try await self.client.query("""
                SELECT count(*)::bigint,COALESCE((SELECT query FROM app_messages WHERE doc_id=\(app) AND conversation_id=\(cid)
                    ORDER BY created_at,id LIMIT 1),'') FROM app_messages WHERE doc_id=\(app) AND conversation_id=\(cid)
                """,logger:self.logger).decode((Int64,String).self) { count=Int(row.0);title=row.1 }
            for try await row in try await self.client.query("""
                SELECT r.status,count(*)::bigint FROM app_messages m JOIN workflow_runs r ON r.id=m.workflow_run_id
                WHERE m.doc_id=\(app) AND m.conversation_id=\(cid) GROUP BY r.status
                """,logger:self.logger).decode((String,Int64).self) { statuses[row.0]=Int(row.1) }
            return(count,title,statuses)
        }
    }
}
