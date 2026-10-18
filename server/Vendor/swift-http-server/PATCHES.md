# dify-sf local patches to swift-http-server 0.3.0

Upstream: https://github.com/swift-server/swift-http-server, revision `cc494f5ceebd06727c6e250bb502c405f912836b` (tag
0.3.0, the revision Vapor 5.0.0-beta.4 resolves to), Apache License 2.0 (see LICENSE.txt). Copied without `.git` and
`.github`; everything else is upstream except the files listed below.

`server/Package.swift` depends on this directory with `.package(path: "Vendor/swift-http-server")`. Its package identity
(`swift-http-server`, the directory name) is the same as that of Vapor's remote dependency
`https://github.com/swift-server/swift-http-server.git`, and SwiftPM lets a root package's local dependency replace a
remote dependency of the same identity anywhere in the graph: Vapor builds against this copy, and `Package.resolved` no
longer lists swift-http-server (local packages are not pinned). `swift package show-dependencies` shows
`swift-http-server</work/Vendor/swift-http-server@unspecified>` under vapor as well as at the top level, and the build
compiles `Vendor/swift-http-server/Sources/NIOHTTPServer/TimeoutHandlers.swift` (see the `.d` files under
`.build/out/Intermediates.noindex/swift-http-server.build`).

SwiftPM 6.4 accepts this override with a warning ("Conflicting identity for swift-http-server: dependency
'github.com/swift-server/swift-http-server' and dependency '.../vendor/swift-http-server' both point to the same package
identity ... This will be escalated to an error in future versions of SwiftPM."). If a later toolchain makes it an
error, the fallback is a mirror (`swift package config set-mirror`) or a vendored Vapor that depends on this copy by path.

## The bug: streaming responses are closed after the read-header timeout (30 s)

dify-sf's event stream (`GET /v1/docs/{doc}/events`, server-sent events) is a response that never ends; the server writes
a ping every 10 s. Every stream was closed after exactly 30 s.

`RequestTimeoutHandler` (upstream `Sources/NIOHTTPServer/TimeoutHandlers.swift`, lines 128-148 at the revision above)
re-arms the read-header timeout when it receives the request's `.end` (lines 139-145), so that the next request on a
keep-alive HTTP/1.1 connection is protected. For a GET the request ends right after its head, while the response is just
starting. If the response takes longer than the read-header timeout (streaming, long polling, a slow handler), the timer
fires and closes the connection under the response being written. Vapor 5.0.0-beta.4 builds its
`NIOHTTPServerConfiguration` without timeouts (`Sources/Vapor/HTTP/Server/NIOHTTPServerAdapter.swift`, lines 160-164), so
the defaults apply (`NIOHTTPServerConfiguration.ConnectionTimeouts.defaults`: idle 60 s, read header 30 s, read body
60 s) and cannot be changed from Vapor.

## The patch (`Sources/NIOHTTPServer/TimeoutHandlers.swift`)

`RequestTimeoutHandler` becomes a `ChannelDuplexHandler` that also sees the outbound `HTTPResponsePart`s. On an HTTP/1.1
connection (`expectMultipleRequests == true`) it re-arms the read-header timeout only once both the request's `.end` has
been received and the response's `.end` has been written, whichever comes last. Everything else is unchanged:

- the read-header timeout still starts when the connection becomes active (or the handler is added to an active
  channel), is cancelled by a request `.head`, and closes the connection when it fires;
- the read-body timeout still runs from the request `.head` to the request `.end`;
- after a complete exchange the next request head is still timed (now from the end of the response, which is also when
  the connection really starts waiting for it);
- HTTP/2 and HTTP/3 stream channels (`expectMultipleRequests == false`) do not look at outbound parts at all.

The state is updated before the response `.end` is forwarded: NIO's `HTTPServerPipelineHandler` delivers a pipelined
next request synchronously while that `.end` is being written, and that request's `.head` must cancel the timer just
armed.

Tests: `Tests/NIOHTTPServerTests/TimeoutHandlerTests.swift` (the two upstream tests that relied on the re-arm at the
request `.end` now also write the response `.end`; three new tests are marked `dify-sf patch`; all 23 timeout handler
tests pass with `swift test --filter TimeoutHandlerTests` in this directory). dify-sf's own suite
checks the behaviour end to end over TCP (`server/Tests/CollabTests/ConnectionTimeoutTests.swift`): an event stream stays
open past 30 s and keeps receiving pings, and an incomplete request head is still closed by the read-header timeout, on a
new connection and on a kept-alive one.

Drop this directory and depend on upstream again (remove the `.package(path:)` line) once upstream has a fix, or once
Vapor lets the application configure or disable the read-header timeout.

## Upstream issue (text, not filed)

**Title:** HTTP/1.1: read-header timeout closes the connection while a long response (SSE, streaming) is still being written

**Body:**

`RequestTimeoutHandler` re-arms the read-header timeout as soon as the request `.end` is received
(`Sources/NIOHTTPServer/TimeoutHandlers.swift`, `channelRead`, case `.end`, lines 139-145 at
cc494f5ceebd06727c6e250bb502c405f912836b). On an HTTP/1.1 keep-alive connection the next request cannot start before
the current response has ended, but the timer starts counting at the end of the *request*. Any response that takes
longer than `readHeader` (default 30 s) — server-sent events, chunked streaming, long polling, a slow handler — is cut off
when the timer fires, even though the server is actively writing to the connection.

Reproduction (plaintext HTTP/1.1, default `ConnectionTimeouts`):

```swift
import BasicContainers
import HTTPTypes
import NIOHTTPServer

let server = NIOHTTPServer(configuration: try .init(
    bindTarget: .hostAndPort(host: "127.0.0.1", port: 8080),
    supportedHTTPVersions: [.http1_1],
    transportSecurity: .plaintext))
try await server.serve { request, context, body, responseSender in
    var writer = try await responseSender.send(HTTPResponse(status: .ok, headerFields: [.contentType: "text/event-stream"]))
    while true {
        var chunk = UniqueArray<UInt8>(copying: ": ping\n\n".utf8)
        try await writer.write(buffer: &chunk)
        try await Task.sleep(for: .seconds(5))
    }
}
```

Then `curl -sN http://127.0.0.1:8080/`: the connection is closed 30 s after the request, while the handler is still
writing. (Observed through Vapor 5.0.0-beta.4, which serves with this package: an SSE response writing a ping every 10 s
was closed 30.000 s after the request, every time; with the fix below it stays open.)

Expected: the stream stays open as long as the handler writes to it; the read-header timeout protects the connection
only while it is waiting for a request head.

Frameworks on top (Vapor 5 beta) build the configuration with the defaults and do not expose `connectionTimeouts`, so
applications cannot work around it by raising or disabling `readHeader`; and disabling it would also drop the
slow-header protection.

Suggested fix: make `RequestTimeoutHandler` a duplex handler and, when `expectMultipleRequests` is true, re-arm the
read-header timeout only when both the request `.end` has been read and the response `.end` has been written (like
`ConnectionIdleTimeoutHandler` already re-arms on the response `.end`). Set that state before forwarding the response
`.end`, since `HTTPServerPipelineHandler` delivers a pipelined next request synchronously during that write. Unit tests
with `EmbeddedChannel`: a request whose response keeps writing body parts for longer than `readHeader` stays open; after
the response `.end`, the header timeout closes an idle connection; a response that ends before the request body does not
start the header timeout until the request `.end`. (`ConnectionIdleTimeoutHandler.write` arms its timer after
`context.write`, so a pipelined request delivered during that write runs with the idle timer armed; the same ordering
fix applies there.)
