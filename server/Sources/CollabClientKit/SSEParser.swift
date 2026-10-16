import CollabCore

/// Incremental parser for `text/event-stream` bodies. Feed bytes as they arrive; it yields complete messages.
public struct SSEParser: Sendable {
    public struct Message: Sendable, Equatable {
        public var event: String
        public var data: String
        public var id: String?
    }

    private var buffer: [UInt8] = []
    private var event = ""
    private var data: [String] = []
    private var id: String?
    /// True when at least one byte (including comment lines) was seen: liveness for the watchdog.
    public private(set) var sawBytes = false

    public init() {}

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [Message] {
        sawBytes = true
        buffer.append(contentsOf: bytes)
        var out: [Message] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = Array(buffer[..<nl])
            buffer.removeSubrange(...nl)
            if line.last == 0x0D { line.removeLast() }
            if line.isEmpty {
                if !data.isEmpty || !event.isEmpty {
                    out.append(Message(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"), id: id))
                }
                event = ""
                data = []
                continue
            }
            if line.first == 0x3A { continue }  // comment (": ping")
            let s = String(decoding: line, as: UTF8.self)
            let name: Substring
            var value: Substring = ""
            if let colon = s.firstIndex(of: ":") {
                name = s[..<colon]
                value = s[s.index(after: colon)...]
                if value.first == " " { value = value.dropFirst() }
            } else {
                name = Substring(s)
            }
            switch name {
            case "event": event = String(value)
            case "data": data.append(String(value))
            case "id": id = String(value)
            default: break
            }
        }
        return out
    }
}
