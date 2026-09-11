import Foundation

public final class EventBridge: @unchecked Sendable {
    public enum Error: Swift.Error, LocalizedError {
        case socketFailed(String)

        // Without LocalizedError, `error.localizedDescription` renders as
        // "The operation couldn't be completed. (… error 0.)" and throws away
        // the reason we went to the trouble of capturing.
        public var errorDescription: String? {
            switch self {
            case .socketFailed(let detail): return detail
            }
        }
    }

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
        // `sun_path` is only 104 bytes. Silently truncating it would make us
        // bind one path while pianobar is told to connect to another, so the
        // app would receive zero events with no error anywhere.
        guard socketPath.utf8.count < sunPathSize else {
            close(listenFD); listenFD = -1
            throw Error.socketFailed(
                "socket path too long (\(socketPath.utf8.count) bytes, max \(sunPathSize - 1)): \(socketPath)")
        }
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

    /// Give up on a client that connects but never sends a terminated record.
    private static let clientReadTimeout = timeval(tv_sec: 5, tv_usec: 0)
    /// Hard cap on one event payload. Real pianobar events are a few hundred
    /// bytes; anything approaching this is a malfunctioning or hostile client.
    private static let maxPayloadBytes = 1 << 20  // 1 MiB

    private func acceptLoop() async {
        while !Task.isCancelled {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                let err = errno
                // The listening socket is gone — stop() closed it, so we're done.
                if err == EBADF || err == EINVAL || listenFD < 0 { return }
                // Anything else is transient (EMFILE under fd pressure,
                // ECONNABORTED, EINTR). Don't end the event stream over it —
                // that would freeze the UI on the last song with no error and
                // no restart. Pause briefly so a persistent failure doesn't
                // spin the CPU, then try again.
                if err != EINTR {
                    usleep(100_000)
                }
                continue
            }
            // Handled inline, on purpose: pianobar opens one connection per
            // event and their order is meaningful (e.g. songfinish before
            // songstart), so concurrent handling could reorder them. The
            // unbounded stall this used to risk is addressed by the receive
            // timeout in handleClient rather than by parallelism.
            handleClient(fd: fd)
        }
    }

    private func handleClient(fd: Int32) {
        defer { close(fd) }
        // Without a receive timeout, a client that connects and never sends the
        // terminator holds this read forever.
        var timeout = Self.clientReadTimeout
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            buf.append(tmp, count: n)
            if buf.last == 0x1e { break } // record separator
            // Bound the buffer so a client that streams without ever sending a
            // terminator can't exhaust memory.
            if buf.count > Self.maxPayloadBytes { return }
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
