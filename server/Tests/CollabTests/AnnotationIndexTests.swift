import CollabRuntime
import CollabStore
import Foundation
import Testing
@testable import CollabServer

@Suite("Durable annotation index", .enabled(if:testDbHost != nil)) struct AnnotationIndexTests {
    @Test func editsAtomicallyInvalidateOldGenerationsAndRestartReclaimsOnlyAnExpiredLease() async throws {
        try await withServerAndRoutes { api,store,_ in
            let token=try await api.setupOwner(), owner=try await api.get("/v1/account",token:token).str("id")
            let app=try await api.post("/v1/apps",#"{"name":"Annotation fixture","mode":"advanced-chat"}"#,token:token).str("id")
            let id=UUID().uuidString.lowercased()
            _ = try await store.insertAnnotations(app,[(id,"question","answer")],account:owner)
            let job=UUID().uuidString.lowercased()
            try await store.configureAnnotationIndex(doc:app,job:job,enable:true,score:0.8,provider:"fixture/p/model",model:"embed",by:owner)
            #expect(try await store.annotationIndexJob(job,doc:app,action:"enable")?.status == "waiting")
            let first=try #require(try await store.claimAnnotationIndex(lease:"process-a"))
            #expect(first.status == "processing" && first.doc == app)
            #expect(try await store.claimAnnotationIndex(lease:"process-b") == nil)
            #expect(try await store.finishAnnotationIndex(first))
            let hit=try await store.recordAnnotationHit(doc:app,generation:first.generation,annotation:id,indexedQuestion:"question",query:"semantic question",user:"visitor",message:"fixture-message",source:"api",score:0.95)
            #expect(hit?.answer == "answer" && hit?.hitCount == 1)
            _ = try await store.updateAnnotation(app,id:id,question:"question",answer:"new answer")
            #expect(try await store.annotationIndex(app)?.generation == first.generation)
            #expect(try await store.recordAnnotationHit(doc:app,generation:first.generation,annotation:id,indexedQuestion:"question",query:"semantic question",user:"visitor",message:"second",source:"api",score:0.95)?.answer == "new answer")
            _ = try await store.updateAnnotation(app,id:id,question:"changed question",answer:"changed answer")
            let dirty=try #require(try await store.annotationIndex(app))
            #expect(dirty.generation != first.generation && dirty.status == "waiting")
            #expect(try await store.recordAnnotationHit(doc:app,generation:first.generation,annotation:id,indexedQuestion:"question",query:"stale",user:"visitor",message:"stale",source:"api",score:1) == nil)
            #expect(!(try await store.finishAnnotationIndex(first)))
            let claimed=try #require(try await store.claimAnnotationIndex(lease:"old-process"))
            _ = try await store.client.query("UPDATE app_annotation_indexes SET lease_until=clock_timestamp()-interval '1 second' WHERE doc_id=\(app)")
            let recovered=try #require(try await store.claimAnnotationIndex(lease:"new-process"))
            #expect(recovered.generation == claimed.generation && recovered.lease == "new-process")
            #expect(!(try await store.finishAnnotationIndex(claimed)))
            #expect(try await store.finishAnnotationIndex(recovered))
            let history=try await store.annotationHits(doc:app,annotation:id,page:1,limit:20)
            #expect(history.total == 2 && history.items.first?.answer == "new answer")
            #expect(try await store.annotationHits(doc:"other-app",annotation:id,page:1,limit:20).total == 0)
            _ = try await store.deleteAnnotations(app,ids:[id])
            #expect(try await store.annotationIndex(app)?.status == "waiting")
            #expect(try await store.annotationHits(doc:app,annotation:id,page:1,limit:20).total == 0)
        }
    }
    @Test func upgradingLegacyFlagsNeverSchedulesPaidEmbeddings() async throws {
        try await withServerAndRoutes { api,store,_ in
            let token=try await api.setupOwner(), owner=try await api.get("/v1/account",token:token).str("id")
            let app=try await api.post("/v1/apps",#"{"name":"Legacy annotation","mode":"advanced-chat"}"#,token:token).str("id")
            try await store.enableAnnotationReply(app,newId:"old-setting",scoreThreshold:0.8,provider:"existing/provider",model:"paid-model",by:owner)
            _ = try await store.insertAnnotations(app,[("old-annotation","old question","old answer")],account:owner)
            try await store.migrate()
            let index=try #require(try await store.annotationIndex(app))
            #expect(index.action == "needs_rebuild" && index.status == "needs_rebuild")
            #expect(try await store.annotationSetting(app)?.id == "old-setting")
            _ = try await store.updateAnnotation(app,id:"old-annotation",question:"edited question",answer:"kept answer")
            #expect(try await store.annotationIndex(app)?.generation == index.generation)
            #expect(try await store.claimAnnotationIndex(lease:"must-not-spend-quota") == nil)
            #expect(try await api.get("/v1/apps/\(app)/annotation-setting",token:token).j["enabled"] == false)
            try await store.configureAnnotationIndex(doc:app,job:"explicit-enable",enable:true,score:0.8,provider:"fixture/provider",model:"local-only",by:owner)
            #expect(try await store.claimAnnotationIndex(lease:"now-authorized")?.model == "local-only")
        }
    }
    @Test func failedIndexJobIsNotCompletedAndModelChangeSupersedesOldWork() async throws {
        try await withServerAndRoutes { api,store,_ in
            let token=try await api.setupOwner(), owner=try await api.get("/v1/account",token:token).str("id")
            let app=try await api.post("/v1/apps",#"{"name":"Index failure","mode":"advanced-chat"}"#,token:token).str("id")
            try await store.configureAnnotationIndex(doc:app,job:"job-a",enable:true,score:0.8,provider:"fixture/p/model",model:"old",by:owner)
            let old=try #require(try await store.claimAnnotationIndex(lease:"lease-a"))
            try await store.configureAnnotationIndex(doc:app,job:"job-b",enable:true,score:0.8,provider:"fixture/p/model",model:"new",by:owner)
            #expect(!(try await store.finishAnnotationIndex(old)))
            #expect(try await store.annotationIndexJob("job-a",doc:app,action:"enable")?.status == "error")
            let current=try #require(try await store.claimAnnotationIndex(lease:"lease-b"))
            #expect(current.model == "new")
            #expect(try await store.finishAnnotationIndex(current,error:"Real index failure"))
            #expect(try await store.annotationIndexJob("job-b",doc:app,action:"enable")?.status == "error")
            #expect(try await store.annotationIndex(app)?.status == "error")
            let response=try await api.get("/v1/apps/\(app)/annotation-setting",token:token)
            #expect(response.j["enabled"] == false)
            try await store.configureAnnotationIndex(doc:app,job:"disable",enable:false,score:1,provider:"",model:"",by:owner)
            #expect(try await store.annotationSetting(app) == nil)
            #expect(try await store.annotationIndexJob("disable",doc:app,action:"disable")?.status == "completed")
        }
    }
}
