// Fixed Dify 8387590 weaviate_vector.py: self-provided named vector `default`, cosine distance, top1,
// score = 1-distance and STRICT score > threshold. No local string similarity or synthetic index completion.
import AsyncHTTPClient
import CollabRuntime
import CollabStore
import Crypto
import Foundation
import NIOCore
import NIOHTTP1

struct AnnotationVectorMatch: Sendable {
    let id: String
    let question: String
    let score: Double
}
struct WeaviateAnnotationIndex: Sendable {
    let url: String
    let key: String
    var client: HTTPClient = .shared
    static func collection(doc: String, generation: String) -> String {
        let digest = SHA256.hash(data: Data(doc.utf8)).map { String(format:"%02x",$0) }.joined()
        return "WinnieAnnotation" + String(digest.prefix(24)) + generation.filter { $0.isHexDigit }
    }
    func request(_ method: HTTPMethod, _ path: String, body: JSONValue? = nil, allowMissing: Bool = false) async throws -> JSONValue {
        let base = url.hasSuffix("/") ? String(url.dropLast()) : url
        guard let parsed = URL(string:base), ["http","https"].contains(parsed.scheme ?? ""), parsed.host != nil,
              parsed.user == nil, parsed.password == nil else { throw NodeError("VectorConfigurationError","Invalid Weaviate service URL") }
        var req=HTTPClientRequest(url:base+path);req.method=method
        if !key.isEmpty { req.headers.add(name:"Authorization",value:"Bearer "+key) }
        if let body { req.headers.add(name:"Content-Type",value:"application/json");req.body = .bytes(ByteBuffer(string:body.compactJSON())) }
        let response=try await client.execute(req,timeout:.seconds(60))
        if allowMissing && response.status.code == 404 { return .null }
        guard (200..<300).contains(Int(response.status.code)) else { throw NodeError("VectorServiceError","Weaviate returned HTTP \(response.status.code)") }
        let data=try await response.body.collect(upTo:16<<20)
        if data.readableBytes == 0 { return .null }
        return try JSONValue.parse(Array(data.readableBytesView))
    }
    func create(_ name: String) async throws {
        // Work is idempotent after a crash; a generation never becomes searchable before all writes succeed.
        if try await request(.GET,"/v1/schema/"+name,allowMissing:true) != .null { return }
        let properties:[JSONValue]=["text","document_id","annotation_id","app_id"].map {
            ["name":.string($0),"dataType":["text"],"tokenization":"field","indexFilterable":true,"indexSearchable":false]
        }
        _ = try await request(.POST,"/v1/schema",body:["class":.string(name),"properties":.array(properties),
            "vectorConfig":["default":["vectorizer":["none":[:]],"vectorIndexType":"hnsw","vectorIndexConfig":["distance":"cosine"]]]])
    }
    func upsert(_ name: String, doc: String, rows: [StoredAnnotation], embeddings: [[Double]]) async throws {
        guard rows.count == embeddings.count else { throw NodeError("VectorServiceError","Embedding count mismatch") }
        let objects:[JSONValue]=try zip(rows,embeddings).map { row,vector in
            guard UUID(uuidString:row.id) != nil, !vector.isEmpty, vector.allSatisfy(\.isFinite) else {
                throw NodeError("VectorServiceError","Invalid annotation id or vector")
            }
            return ["class":.string(name),"id":.string(row.id),"properties":["text":.string(row.question),"document_id":.string(row.id),
                "annotation_id":.string(row.id),"app_id":.string(doc)],"vectors":["default":.array(vector.map(JSONValue.double))]]
        }
        let result=try await request(.POST,"/v1/batch/objects",body:["objects":.array(objects)])
        guard let answers=result.array, answers.count == rows.count, answers.allSatisfy({ $0["result"]?["status"]?.string == "SUCCESS" }) else {
            throw NodeError("VectorServiceError","Weaviate did not accept every annotation vector")
        }
    }
    func delete(_ name: String) async throws { _ = try await request(.DELETE,"/v1/schema/"+name,allowMissing:true) }
    func nearest(_ name: String, doc: String, vector: [Double], threshold: Double) async throws -> AnnotationVectorMatch? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite), threshold.isFinite else { throw NodeError("VectorServiceError","Invalid search vector or threshold") }
        let numbers=JSONValue.array(vector.map(JSONValue.double)).compactJSON()
        let query="{Get{\(name)(nearVector:{vector:\(numbers),targetVectors:[\"default\"]},limit:1){annotation_id app_id text _additional{distance}}}}"
        let response=try await request(.POST,"/v1/graphql",body:["query":.string(query)])
        guard response["errors"] == nil, let items=response["data"]?["Get"]?[name]?.array else { throw NodeError("VectorServiceError","Weaviate search failed") }
        guard let item=items.first else { return nil }
        guard item["app_id"]?.string == doc, let id=item["annotation_id"]?.string, let text=item["text"]?.string,
              let distance=item["_additional"]?["distance"]?.double, distance.isFinite else { throw NodeError("VectorServiceError","Invalid vector result") }
        let score=1-distance
        // Feature-level `score_threshold or 1` is deliberately preserved, including configured zero.
        guard score > (threshold == 0 ? 1 : threshold) else { return nil }
        return .init(id:id,question:text,score:score)
    }
}
