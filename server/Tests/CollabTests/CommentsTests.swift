import CollabClientKit
import CollabCore
@testable import CollabStore
import Foundation
import Testing
@testable import CollabServer

/// Canvas comments without a database: the stream notification, validation, ids, wire shape (authors are accounts, 1.8). Routes against Postgres:
/// `PostgresIntegrationTests.commentRoutes...`.
@Suite("Comments")
struct CommentsTests {
    @Test func theNotificationFrameHasNoIdAndOldParsersIgnoreIt() throws {
        let frame = try CommentsEvent(comment: "c1", action: .created).sseFrame()
        #expect(frame == "event: comments\ndata: {\"action\":\"created\",\"comment\":\"c1\"}\n\n")
        #expect(!frame.contains("id:"))
        // A client that does not know the event (the Swift client kit, any pre-comments client): the message parses, its
        // id is still the last commit's (the resume point does not move), and StreamEvent.parse ignores it.
        var parser = SSEParser()
        let commit = try StreamEvent.commit(LogEntry(seq: 4, client: "c", cseq: 1, base: 3, op: .removeEdge("e"))).sseFrame()
        let msgs = parser.feed(Array((commit + frame + ": ping\n\n").utf8))
        #expect(msgs.count == 2)
        #expect(msgs[1].event == "comments" && msgs[1].id == "4")
        #expect(try StreamEvent.parse(event: msgs[1].event, data: msgs[1].data) == nil)
        #expect(try WireJSON.decode(CommentsEvent.self, from: msgs[1].data) == CommentsEvent(comment: "c1", action: .created))
        for a in ["created", "updated", "deleted", "resolved", "reply"] {
            #expect(CommentsEvent.Action(rawValue: a) != nil)
        }
    }

    @Test func theAppNotificationFrameHasNoIdAndOldParsersIgnoreIt() throws {
        let frame = try AppEvent().sseFrame()
        #expect(frame == "event: app\ndata: {\"action\":\"updated\"}\n\n")
        var parser = SSEParser()
        let commit = try StreamEvent.commit(LogEntry(seq: 7, client: "c", cseq: 1, base: 6, op: .removeEdge("e"))).sseFrame()
        let msgs = parser.feed(Array((commit + frame).utf8))
        #expect(msgs.count == 2 && msgs[1].event == "app" && msgs[1].id == "7")
        #expect(try StreamEvent.parse(event: msgs[1].event, data: msgs[1].data) == nil)
        #expect(try WireJSON.decode(AppEvent.self, from: msgs[1].data) == AppEvent(action: .updated))
    }

    @Test func contentRulesAreDifys() throws {
        try Routes.validateContent("ok")
        try Routes.validateContent(String(repeating: "字", count: 1000))  // characters, not bytes
        #expect(throws: ServerError.self) { try Routes.validateContent("") }
        #expect(throws: ServerError.self) { try Routes.validateContent(" \n\t ") }
        #expect(throws: ServerError.self) { try Routes.validateContent(String(repeating: "a", count: 1001)) }
    }

    @Test func idsAreTimeOrderedUUIDv7() {
        let a = PostgresStore.newCommentId(now: Date(timeIntervalSince1970: 1_700_000_000))
        let b = PostgresStore.newCommentId(now: Date(timeIntervalSince1970: 1_700_000_001))
        #expect(a.count == 36 && Array(a)[14] == "7" && "89ab".contains(Array(a)[19]))
        #expect(a < b && a.hasPrefix("018bcfe5-6800-7"))
        #expect(Set((0..<100).map { _ in PostgresStore.newCommentId() }).count == 100)
    }

    @Test func wireShapeUsesDifyFieldNamesAndISOTimestamps() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000.25)
        let c = StoredComment(id: "x", positionX: 1.5, positionY: -2, content: "hi", createdBy: "alice", createdAt: t, updatedAt: t,
                              resolved: false, resolvedBy: nil, resolvedAt: nil, mentions: ["bob", "eve"],
                              replies: [StoredReply(id: "r", content: "yo", createdBy: "bob", createdAt: t, updatedAt: t, mentions: [])])
        let names: Routes.Names = ["alice": ("Alice", nil), "bob": ("Bo", "https://example.com/bo.png")]
        let text = try WireJSON.encodeString(Routes.wire(c, names: names))
        #expect(text == #"{"content":"hi","created_at":"2023-11-14T22:13:20.250Z","created_by":"alice","created_by_name":"Alice","id":"x","#
            + #""mentions":[{"account":"bob","avatar_url":"https://example.com/bo.png","name":"Bo"},{"account":"eve"}],"position_x":1.5,"position_y":-2,"#
            + #""replies":[{"content":"yo","created_at":"2023-11-14T22:13:20.250Z","created_by":"bob","created_by_avatar_url":"https://example.com/bo.png","#
            + #""created_by_name":"Bo","id":"r","#
            + #""mentions":[],"updated_at":"2023-11-14T22:13:20.250Z"}],"reply_count":1,"resolved":false,"updated_at":"2023-11-14T22:13:20.250Z"}"#)
    }
}
