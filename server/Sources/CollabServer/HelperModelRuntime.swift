// Dify 1.17.1 core/plugin/impl/model.py: reuse the installed signed model plugin for auxiliary modalities.
import CollabRuntime
import Foundation

extension PluginDaemonModelRuntime {
    func helperData(provider: String, model: String, type: String, extra: JSONObject) async throws -> (String, JSONValue) {
        let (plugin, name) = try Self.split(provider)
        let credentials = try await credentials(provider: provider, model: model, modelType: type)
        var data = extra
        data["provider"] = .string(name); data["model"] = .string(model); data["model_type"] = .string(type)
        data["credentials"] = .object(credentials)
        return (plugin, PluginDaemonWire.dispatchBody(userId: nil, appId: appId, data: data))
    }
    func voices(provider: String, model: String, language: String?) async throws -> [JSONValue] {
        let (plugin, body) = try await helperData(provider: provider, model: model, type: "tts", extra: ["language": language.map(JSONValue.string) ?? .null])
        for try await result in daemon.dispatch("tts/model/voices", pluginId: plugin, body: body) {
            guard let voices = result["voices"]?.array else { throw NodeError("TTSResponseError", "Invalid voices response") }
            return voices.compactMap { voice in
                guard let value = voice["value"]?.string, let name = voice["name"]?.string else { return nil }
                return .object(["value": .string(value), "name": .string(name)])
            }
        }
        throw NodeError("TTSResponseError", "The model returned no voices")
    }
    func audio(provider: String, model: String, text: String, voice: String) async throws -> (Data, String) {
        let (plugin, body) = try await helperData(provider: provider, model: model, type: "tts", extra: [
            "tenant_id": .string(daemon.tenant), "content_text": .string(text), "voice": .string(voice)])
        var bytes = Data(), mime: String?
        for try await result in daemon.dispatch("tts/invoke", pluginId: plugin, body: body) {
            try Task.checkCancellation()
            guard let hex = result["result"]?.string, hex.utf8.count % 2 == 0,
                  let type = result["mime_type"]?.string,
                  ["audio/mpeg", "audio/mp3", "audio/wav", "audio/x-wav", "audio/ogg", "audio/flac", "audio/aac", "audio/mp4"].contains(type),
                  mime == nil || mime == type, bytes.count + hex.utf8.count / 2 <= 16 << 20 else {
                throw NodeError("TTSResponseError", "Invalid or oversized audio response")
            }
            mime = type
            let chars = Array(hex.utf8)
            func nibble(_ c: UInt8) -> UInt8? { switch c { case 48...57: c - 48; case 65...70: c - 55; case 97...102: c - 87; default: nil } }
            for i in stride(from: 0, to: chars.count, by: 2) {
                guard let a = nibble(chars[i]), let b = nibble(chars[i+1]) else { throw NodeError("TTSResponseError", "Invalid audio encoding") }
                bytes.append(a * 16 + b)
            }
        }
        guard !bytes.isEmpty, let mime else { throw NodeError("TTSResponseError", "The model returned no audio") }
        return (bytes, mime)
    }
    func embeddings(provider: String, model: String, texts: [String], query: Bool) async throws -> [[Double]] {
        let (plugin, body) = try await helperData(provider: provider, model: model, type: "text-embedding", extra: [
            "texts": .array(texts.map(JSONValue.string)), "input_type": .string(query ? "query" : "document")])
        for try await result in daemon.dispatch("text_embedding/invoke", pluginId: plugin, body: body) {
            guard let vectors = result["embeddings"]?.array, vectors.count == texts.count else {
                throw NodeError("EmbeddingResponseError", "Embedding count differs from input count")
            }
            var width: Int?
            return try vectors.map { vector in
                guard let values = vector.array, !values.isEmpty, values.count <= 65536 else { throw NodeError("EmbeddingResponseError", "Invalid vector dimensions") }
                if let width, width != values.count { throw NodeError("EmbeddingResponseError", "Vector dimensions differ") }
                width = values.count
                return try values.map { value in
                    guard let x = value.double, x.isFinite else { throw NodeError("EmbeddingResponseError", "Vector contains a non-finite number") }
                    return x
                }
            }
        }
        throw NodeError("EmbeddingResponseError", "The model returned no embeddings")
    }
}
