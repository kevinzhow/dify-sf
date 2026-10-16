import Foundation

/// Async line stream over a file descriptor (FileHandle.bytes does not exist on Linux).
public enum LineStream {
    public static func make(fd: Int32) -> AsyncStream<String> {
        AsyncStream { cont in
            let thread = Thread {
                var pending = [UInt8]()
                var buf = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n <= 0 { break }
                    pending.append(contentsOf: buf[0..<n])
                    while let nl = pending.firstIndex(of: 0x0A) {
                        cont.yield(String(decoding: pending[..<nl], as: UTF8.self))
                        pending.removeSubrange(...nl)
                    }
                }
                cont.finish()
            }
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    public static var stdin: AsyncStream<String> { make(fd: 0) }
}

nonisolated(unsafe) private var stdoutLock = NSLock()

/// Prints one line to stdout and flushes (worker -> orchestrator protocol).
public func emit(_ line: String) {
    stdoutLock.lock()
    defer { stdoutLock.unlock() }
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}
