// Durable annotation-only vector index work. SQL remains the source of truth; Weaviate is a replaceable index.
import Foundation
import PostgresNIO

public struct StoredAnnotationIndex: Sendable {
    public var doc: String
    public var generation: String
    public var activeGeneration: String?
    public var action: String
    public var status: String
    public var provider: String
    public var model: String
    public var job: String?
    public var lease: String?
}
public struct AnnotationHit: Sendable {
    public var id: String
    public var question: String
    public var answer: String
    public var query: String
    public var user: String
    public var message: String
    public var source: String
    public var score: Double
    public var createdAt: Date
}
enum AnnotationIndexSchema {
    static let statements = [
        """
        CREATE TABLE IF NOT EXISTS app_annotation_index_jobs (
            id text PRIMARY KEY, doc_id text NOT NULL REFERENCES documents(id), action text NOT NULL,
            status text NOT NULL, error text NOT NULL DEFAULT '', created_at timestamptz NOT NULL DEFAULT clock_timestamp())
        """,
        """
        CREATE TABLE IF NOT EXISTS app_annotation_indexes (
            doc_id text PRIMARY KEY REFERENCES documents(id), generation text NOT NULL, active_generation text,
            action text NOT NULL, status text NOT NULL, provider text NOT NULL, model text NOT NULL,
            job_id text REFERENCES app_annotation_index_jobs(id), lease_id text, lease_until timestamptz,
            updated_at timestamptz NOT NULL DEFAULT clock_timestamp())
        """,
        """
        CREATE TABLE IF NOT EXISTS app_annotation_hits (
            id text PRIMARY KEY, doc_id text NOT NULL REFERENCES documents(id), annotation_id text NOT NULL,
            question text NOT NULL, content text NOT NULL, query text NOT NULL, user_id text NOT NULL,
            message_id text NOT NULL, source text NOT NULL, score double precision NOT NULL,
            created_at timestamptz NOT NULL DEFAULT clock_timestamp())
        """,
        "CREATE INDEX IF NOT EXISTS annotation_hits_app_annotation ON app_annotation_hits(doc_id, annotation_id, created_at DESC)",
        // Invalidate in the SAME transaction as CRUD/import. A process death cannot leave a falsely ready index.
        // Answers are always read fresh from SQL; only a changed question requires a new embedding.
        """
        CREATE OR REPLACE FUNCTION collab_invalidate_annotation_index() RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE app text;
        BEGIN
            IF TG_OP = 'UPDATE' THEN
                IF OLD.question IS NOT DISTINCT FROM NEW.question THEN RETURN NEW; END IF;
            END IF;
            IF TG_OP = 'DELETE' THEN
                app = OLD.doc_id;
                DELETE FROM app_annotation_hits WHERE doc_id=app AND annotation_id=OLD.id;
            ELSE app = NEW.doc_id; END IF;
            UPDATE app_annotation_indexes SET generation = gen_random_uuid()::text, status = 'waiting',
                job_id = CASE WHEN status IN ('waiting','processing') THEN job_id ELSE NULL END,
                lease_id = NULL, lease_until = NULL, updated_at = clock_timestamp()
                WHERE doc_id = app AND action = 'enable';
            IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
        END $$
        """,
        "DROP TRIGGER IF EXISTS collab_annotation_index_dirty ON app_annotations",
        "CREATE TRIGGER collab_annotation_index_dirty AFTER INSERT OR UPDATE OR DELETE ON app_annotations FOR EACH ROW EXECUTE FUNCTION collab_invalidate_annotation_index()",
        // Old settings were only flags. Keep the data, but require an explicit enable before spending
        // embedding quota; migrating or editing an annotation must never automatically call a model.
        """
        INSERT INTO app_annotation_indexes(doc_id,generation,action,status,provider,model)
            SELECT doc_id,gen_random_uuid()::text,'needs_rebuild','needs_rebuild',embedding_provider_name,embedding_model_name
            FROM app_annotation_settings ON CONFLICT(doc_id) DO NOTHING
        """,
    ]
}

extension PostgresStore {
    private static let annotationIndexColumns = "doc_id,generation,active_generation,action,status,provider,model,job_id,lease_id"
    private static func decodeIndex(_ row: PostgresRow) throws -> StoredAnnotationIndex {
        let r = try row.decode((String,String,String?,String,String,String,String,String?,String?).self)
        return .init(doc:r.0,generation:r.1,activeGeneration:r.2,action:r.3,status:r.4,provider:r.5,model:r.6,job:r.7,lease:r.8)
    }
    public func annotationIndex(_ doc: String) async throws -> StoredAnnotationIndex? {
        try await bounded {
            for try await row in try await self.client.query("SELECT \(unescaped: Self.annotationIndexColumns) FROM app_annotation_indexes WHERE doc_id=\(doc)", logger:self.logger) { return try Self.decodeIndex(row) }
            return nil
        }
    }
    public func configureAnnotationIndex(doc: String, job: String, enable: Bool, score: Double, provider: String, model: String, by: String) async throws {
        let action = enable ? "enable" : "disable", generation = UUID().uuidString.lowercased()
        let jobStatus = enable ? "waiting" : "completed"
        let linkedJob: String? = enable ? job : nil
        try await bounded {
            try await self.client.withTransaction(logger:self.logger) { tx in
                _ = try await tx.query("SELECT id FROM documents WHERE id=\(doc) FOR UPDATE",logger:self.logger)
                _ = try await tx.query("""
                    UPDATE app_annotation_index_jobs SET status='error',error='Superseded by a newer configuration'
                        WHERE doc_id=\(doc) AND status IN ('waiting','processing')
                    """,logger:self.logger)
                if enable {
                    let setting = UUID().uuidString.lowercased()
                    _ = try await tx.query("""
                        INSERT INTO app_annotation_settings(doc_id,id,score_threshold,embedding_provider_name,embedding_model_name,created_by,updated_by)
                        VALUES(\(doc),\(setting),\(score),\(provider),\(model),\(by),\(by))
                        ON CONFLICT(doc_id) DO UPDATE SET score_threshold=EXCLUDED.score_threshold,
                            embedding_provider_name=EXCLUDED.embedding_provider_name,embedding_model_name=EXCLUDED.embedding_model_name,
                            updated_by=EXCLUDED.updated_by,updated_at=clock_timestamp()
                        """,logger:self.logger)
                } else { _ = try await tx.query("DELETE FROM app_annotation_settings WHERE doc_id=\(doc)",logger:self.logger) }
                _ = try await tx.query("INSERT INTO app_annotation_index_jobs(id,doc_id,action,status) VALUES(\(job),\(doc),\(action),\(jobStatus))",logger:self.logger)
                _ = try await tx.query("""
                    INSERT INTO app_annotation_indexes(doc_id,generation,action,status,provider,model,job_id)
                        VALUES(\(doc),\(generation),\(action),'waiting',\(provider),\(model),\(linkedJob))
                    ON CONFLICT(doc_id) DO UPDATE SET generation=EXCLUDED.generation,action=EXCLUDED.action,status='waiting',
                        provider=CASE WHEN \(enable) THEN EXCLUDED.provider ELSE app_annotation_indexes.provider END,
                        model=CASE WHEN \(enable) THEN EXCLUDED.model ELSE app_annotation_indexes.model END,
                        job_id=EXCLUDED.job_id,lease_id=NULL,lease_until=NULL,updated_at=clock_timestamp()
                    """,logger:self.logger)
            }
        }
    }
    public func annotationIndexJob(_ id: String, doc: String, action: String) async throws -> (status:String,error:String)? {
        try await bounded {
            for try await r in try await self.client.query("SELECT status,error FROM app_annotation_index_jobs WHERE id=\(id) AND doc_id=\(doc) AND action=\(action)",logger:self.logger) {
                return try r.decode((String,String).self)
            }; return nil
        }
    }
    public func claimAnnotationIndex(lease: String) async throws -> StoredAnnotationIndex? {
        try await bounded {
            for try await row in try await self.client.query("""
                WITH pending AS (
                    SELECT doc_id FROM app_annotation_indexes WHERE status='waiting' OR (status='processing' AND lease_until<clock_timestamp())
                        OR (action='disable' AND status='error' AND updated_at<clock_timestamp()-interval '30 seconds')
                    ORDER BY updated_at FOR UPDATE SKIP LOCKED LIMIT 1)
                UPDATE app_annotation_indexes i SET status='processing',lease_id=\(lease),lease_until=clock_timestamp()+interval '120 seconds',updated_at=clock_timestamp()
                FROM pending p WHERE i.doc_id=p.doc_id RETURNING \(unescaped: Self.annotationIndexColumns.split(separator: ",").map { "i."+$0 }.joined(separator: ","))
                """,logger:self.logger) { return try Self.decodeIndex(row) }; return nil
        }
    }
    public func renewAnnotationIndex(_ index: StoredAnnotationIndex) async throws -> Bool {
        try await bounded {
            for try await _ in try await self.client.query("""
                UPDATE app_annotation_indexes SET lease_until=clock_timestamp()+interval '120 seconds'
                WHERE doc_id=\(index.doc) AND generation=\(index.generation) AND lease_id=\(index.lease) AND status='processing'
                    AND lease_until>clock_timestamp() RETURNING doc_id
                """,logger:self.logger) { return true }; return false
        }
    }
    @discardableResult public func finishAnnotationIndex(_ index: StoredAnnotationIndex, error: String? = nil) async throws -> Bool {
        let status = error == nil ? "completed" : "error"
        return try await bounded {
            try await self.client.withTransaction(logger:self.logger) { tx in
                var won = false
                for try await _ in try await tx.query("""
                    UPDATE app_annotation_indexes SET status=\(status),lease_id=NULL,lease_until=NULL,updated_at=clock_timestamp(),
                        active_generation=CASE WHEN \(error == nil && index.action == "enable") THEN generation ELSE active_generation END
                    WHERE doc_id=\(index.doc) AND generation=\(index.generation) AND lease_id=\(index.lease)
                      AND status='processing' AND lease_until>clock_timestamp() RETURNING doc_id
                    """,logger:self.logger) { won = true }
                if won, let job = index.job {
                    _ = try await tx.query("UPDATE app_annotation_index_jobs SET status=\(status),error=\(error ?? "") WHERE id=\(job)",logger:self.logger)
                }
                return won
            }
        }
    }
    /// Compare the generation and exact indexed question under the index lock, then record the SQL answer actually used.
    public func recordAnnotationHit(doc: String, generation: String, annotation: String, indexedQuestion: String,
                                    query: String, user: String, message: String, source: String, score: Double) async throws -> StoredAnnotation? {
        try await bounded {
            try await self.client.withTransaction(logger:self.logger) { tx in
                // CRUD takes the annotation row before its invalidation trigger takes the index row.
                // Match that order here to avoid a row/index lock inversion.
                var exists = false
                for try await _ in try await tx.query("""
                    SELECT id FROM app_annotations WHERE doc_id=\(doc) AND id=\(annotation) AND question=\(indexedQuestion) FOR UPDATE
                    """,logger:self.logger) { exists = true }
                guard exists else { return nil }
                var ready = false
                for try await _ in try await tx.query("""
                    SELECT i.doc_id FROM app_annotation_indexes i JOIN app_annotation_settings s ON s.doc_id=i.doc_id
                    WHERE i.doc_id=\(doc) AND i.generation=\(generation) AND i.status='completed' AND i.action='enable' FOR SHARE OF i
                    """,logger:self.logger) { ready = true }
                guard ready else { return nil }
                for try await row in try await tx.query("""
                    UPDATE app_annotations SET hit_count=hit_count+1
                    WHERE doc_id=\(doc) AND id=\(annotation) AND question=\(indexedQuestion)
                    RETURNING id,question,content,hit_count::bigint,created_at
                    """,logger:self.logger) {
                    let a = try row.decode((String,String,String,Int,Date).self), id = UUID().uuidString.lowercased()
                    _ = try await tx.query("""
                        INSERT INTO app_annotation_hits(id,doc_id,annotation_id,question,content,query,user_id,message_id,source,score)
                        VALUES(\(id),\(doc),\(a.0),\(a.1),\(a.2),\(query),\(user),\(message),\(source),\(score))
                        """,logger:self.logger)
                    return StoredAnnotation(id:a.0,question:a.1,answer:a.2,hitCount:a.3,createdAt:a.4)
                }; return nil
            }
        }
    }
    public func annotationHits(doc: String, annotation: String, page: Int, limit: Int) async throws -> (items:[AnnotationHit], total:Int) {
        try await bounded {
            var items:[AnnotationHit]=[], total=0
            for try await n in try await self.client.query("SELECT count(*)::bigint FROM app_annotation_hits WHERE doc_id=\(doc) AND annotation_id=\(annotation)",logger:self.logger).decode(Int.self) { total=n }
            for try await row in try await self.client.query("""
                SELECT id,question,content,query,user_id,message_id,source,score,created_at FROM app_annotation_hits
                WHERE doc_id=\(doc) AND annotation_id=\(annotation) ORDER BY created_at DESC,id DESC LIMIT \(limit) OFFSET \((page-1)*limit)
                """,logger:self.logger) {
                let x=try row.decode((String,String,String,String,String,String,String,Double,Date).self)
                items.append(.init(id:x.0,question:x.1,answer:x.2,query:x.3,user:x.4,message:x.5,source:x.6,score:x.7,createdAt:x.8))
            }; return (items,total)
        }
    }
}
