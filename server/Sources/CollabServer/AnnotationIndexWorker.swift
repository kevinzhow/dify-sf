import CollabRuntime
import CollabStore
import Foundation
import Logging
import ServiceLifecycle

struct AnnotationIndexWorker: Service {
    let routes: Routes
    let readiness: DatabaseReadiness
    func run() async throws {
        try await withGracefulShutdownHandler {
            do { try await cancelWhenGracefulShutdown { try await readiness.wait() } } catch { return }
            while !Task.isCancelled {
                await routes.sweepAnnotationIndexes()
                do { try await cancelWhenGracefulShutdown { try await Task.sleep(for:.seconds(5)) } } catch { break }
            }
        } onGracefulShutdown: {}
    }
}
extension Routes {
    var annotationVectors: WeaviateAnnotationIndex? {
        config.annotationWeaviateURL.isEmpty ? nil : .init(url:config.annotationWeaviateURL,key:config.annotationWeaviateKey)
    }
    func sweepAnnotationIndexes() async {
        guard let vector = annotationVectors else { return }
        for _ in 0..<4 {
            guard !Task.isCancelled else { return }
            let index: StoredAnnotationIndex
            do {
                guard let claimed=try await store.claimAnnotationIndex(lease:UUID().uuidString.lowercased()) else { return }
                index=claimed
            } catch { logger.error("Could not claim annotation indexing work");return }
            let collection=WeaviateAnnotationIndex.collection(doc:index.doc,generation:index.generation)
            do {
                guard try await store.renewAnnotationIndex(index) else { continue }
                if index.action == "enable" {
                    let model=try helperRuntime(app:index.doc)
                    let rows=try await store.allAnnotations(index.doc)
                    try await vector.create(collection)
                    for offset in stride(from:0,to:rows.count,by:16) {
                        try Task.checkCancellation()
                        guard try await store.renewAnnotationIndex(index) else { throw CancellationError() }
                        let batch=Array(rows[offset..<min(offset+16,rows.count)])
                        let values=try await model.embeddings(provider:index.provider,model:index.model,texts:batch.map(\.question),query:false)
                        try await vector.upsert(collection,doc:index.doc,rows:batch,embeddings:values)
                    }
                } else {
                    try await vector.delete(collection)
                    if let active=index.activeGeneration { try await vector.delete(WeaviateAnnotationIndex.collection(doc:index.doc,generation:active)) }
                }
                let won=try await store.finishAnnotationIndex(index)
                if !won { try? await vector.delete(collection) }
                else if index.action == "enable", let old=index.activeGeneration, old != index.generation {
                    try? await vector.delete(WeaviateAnnotationIndex.collection(doc:index.doc,generation:old))
                }
            } catch is CancellationError {
                // Process cancellation leaves its lease for the next process; a superseded generation is private garbage.
                if !Task.isCancelled { try? await vector.delete(collection) }
                if Task.isCancelled { return }
            } catch {
                _ = try? await store.finishAnnotationIndex(index,error:"Embedding or vector indexing failed. Check the selected model and Weaviate, then retry.")
                logger.warning("Annotation indexing failed; no ready index was published")
            }
        }
    }
    /// Original AdvancedChatAppRunner checks annotation replies before constructing/running workflow nodes.
    /// A vector-service/model failure follows the ordinary workflow path, never string matching.
    func matchedAnnotation(_ message: StoredChatMessage) async -> (annotation:StoredAnnotation,score:Double)? {
        guard let vector=annotationVectors else { return nil }
        do {
            guard let setting=try await store.annotationSetting(message.docId),
                  let index=try await store.annotationIndex(message.docId), index.action == "enable", index.status == "completed",
                  index.provider == setting.embeddingProviderName, index.model == setting.embeddingModelName else { return nil }
            let runtime=try helperRuntime(app:message.docId)
            let vectors=try await runtime.embeddings(provider:index.provider,model:index.model,texts:[message.query],query:true)
            let collection=WeaviateAnnotationIndex.collection(doc:message.docId,generation:index.generation)
            guard let result=try await vector.nearest(collection,doc:message.docId,vector:vectors[0],threshold:setting.scoreThreshold),
                  let annotation=try await store.recordAnnotationHit(doc:message.docId,generation:index.generation,annotation:result.id,
                    indexedQuestion:result.question,query:message.query,user:message.endUserId ?? message.accountId,message:message.id,
                    source:message.endUserId == nil ? "console" : "api",score:result.score) else { return nil }
            return (annotation,result.score)
        } catch { logger.warning("Annotation lookup failed; continuing the workflow");return nil }
    }
}

/// Annotation matches bypass all graph nodes, while retaining this server's durable chat/run ledger.
extension RunExecution {
    func completeFromAnnotation(_ original: StoredChatMessage, annotation: StoredAnnotation, score: Double) async {
        var message = original
        message.answer = annotation.answer
        var metadata = (try? JSONValue.parse(message.metadata))?.object ?? [:]
        metadata["annotation_reply"] = ["id":.string(annotation.id),"score":.double(score)]
        metadata["usage"] = LLMUsage.empty.json
        message.metadata = JSONValue.object(metadata).compactJSON()
        do {
            guard try await routes.store.saveChatProgress(runId:runId,lease:lease,answer:message.answer,reasoning:message.reasoning,
                files:message.outputFiles,metadata:message.metadata) else { throw ChatStoreError.leaseLost }
            let started = encoderBox.withLock { $0.encode(.runStarted) }
            for frame in started { await publish(frame) }
            await channel.publish(Self.sse(["event":"message","task_id":.string(taskId),"workflow_run_id":.string(runId),
                "message_id":.string(message.id),"id":.string(message.id),"conversation_id":.string(message.conversationId),
                "answer":.string(message.answer),"created_at":Routes.epochSeconds(message.createdAt)]),chatOffset:message.answer.utf8.count)
            try await routes.store.finishWorkflowRun(id:runId,status:"succeeded",outputs:JSONValue.object(["answer":.string(message.answer)]).compactJSON(),
                error:nil,elapsedTime:Date().timeIntervalSince(message.createdAt),totalTokens:0,totalSteps:0,exceptionsCount:0,finishedAt:Date(),chatLease:lease)
        } catch {
            // A concurrent stop retains its terminal. An actual persistence failure becomes failed, never empty success.
            let leaseLost: Bool
            if case .leaseLost? = error as? ChatStoreError { leaseLost = true } else { leaseLost = false }
            if !leaseLost {
                try? await routes.store.finishWorkflowRun(id:runId,status:"failed",outputs:nil,error:"Could not persist the annotation reply",
                    elapsedTime:0,totalTokens:0,totalSteps:0,exceptionsCount:0,finishedAt:Date(),chatLease:lease)
            }
        }
        await routes.finishRunWithoutEngine(runId)
        await routes.runs.remove(taskId,lease:lease)
    }
}
