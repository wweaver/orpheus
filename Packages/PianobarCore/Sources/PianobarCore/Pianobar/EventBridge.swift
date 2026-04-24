import Foundation

public final class EventBridge: @unchecked Sendable {
    public enum Error: Swift.Error { case socketFailed(String) }

    public let socketPath: String
    private var listenFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?

    private let continuation: AsyncStream<PianobarEvent>.Continuation
    public let events: AsyncStream<PianobarEvent>

    public init(socketPath: String) throws {
        self.socketPath = socketPath
        var cont: AsyncStream<PianobarEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func start() async throws {
        unlink(socketPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw Error.socketFailed("socket: \(String(cString: strerror(errno)))")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: sunPathSize) {
                    strncpy($0, src, sunPathSize - 1)
                }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
        }
        guard bindResult == 0 else {
            throw Error.socketFailed("bind: \(String(cString: strerror(errno)))")
        }
        guard listen(listenFD, 8) == 0 else {
            throw Error.socketFailed("listen: \(String(cString: strerror(errno)))")
        }

        acceptTask = Task.detached { [weak self] in
            await self?.acceptLoop()
        }
    }

    public func stop() async {
        acceptTask?.cancel()
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
        continuation.finish()
    }

    private func acceptLoop() async {
        while !Task.isCancelled {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { continue }
            handleClient(fd: fd)
        }
    }

    private func handleClient(fd: Int32) {
        defer { close(fd) }
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            buf.append(tmp, count: n)
            if buf.last == 0x1e { break } // record separator
        }
        // Strip trailing separator, split first line from payload.
        if buf.last == 0x1e { buf.removeLast() }
        if buf.last == 0x0a { buf.removeLast() }
        guard let text = String(data: buf, encoding: .utf8) else { return }
        let eventType: String
        let payload: String
        if let newline = text.firstIndex(of: "\n") {
            eventType = String(text[..<newline])
            payload = String(text[text.index(after: newline)...])
        } else {
            eventType = text
            payload = ""
        }
        if let event = EventParser.parse(eventType: eventType, payload: payload) {
            continuation.yield(event)
        }
    }
}
