import Foundation

public actor PianobarCtrl {
    public enum Error: Swift.Error {
        case openFailed(String)
        // Carries the underlying error rather than `errno`, which by the time a
        // Swift `FileHandle` throw is caught may already have been overwritten
        // by unrelated syscalls.
        case writeFailed(Swift.Error)
    }

    private let fifoPath: String
    private var handle: FileHandle?

    public init(fifoPath: String) {
        self.fifoPath = fifoPath
    }

    // pianobar's `p` is a single play/pause *toggle*; there is no separate
    // play or pause command, so all three map to the same write.
    //
    // Known pianobar limitation (intentionally not worked around): while
    // paused, pianobar stops reading the Pandora audio stream. After a pause
    // longer than its ~15–30s audio buffer, the CDN connection goes idle and is
    // dropped (and/or the signed URL expires). On resume pianobar plays out the
    // buffered tail, hits EOF, treats it as end-of-track, and advances to the
    // next song. pianobar exposes no way to re-fetch the current song, so we
    // rely on its buffer and accept this — short pauses resume normally.
    public func play()          async throws { try await write("p\n") }
    public func pause()         async throws { try await write("p\n") }
    public func togglePlay()    async throws { try await write("p\n") }
    public func next()          async throws { try await write("n\n") }
    public func love()          async throws { try await write("+\n") }
    public func ban()           async throws { try await write("-\n") }
    public func tired()         async throws { try await write("t\n") }
    public func bookmarkSong()  async throws { try await write("b\n") }
    public func bookmarkArtist() async throws { try await write("b\na\n") }

    public func switchStation(index: Int) async throws {
        try await write("s\(index)\n")
    }

    /// Answers pianobar's initial "Select station:" prompt on first launch.
    /// Unlike `switchStation`, which uses the runtime `s<N>` command, this
    /// sends the plain digits that pianobar expects at the startup prompt.
    public func selectStationAtPrompt(index: Int) async throws {
        try await write("\(index)\n")
    }

    public func createStationFromSong()   async throws { try await write("c\n") }
    public func createStationFromArtist() async throws { try await write("v\n") }

    /// Drives pianobar's interactive create-station flow over the FIFO.
    /// Sequence: `c` → kind (`s` song / `a` artist / etc.) → search query →
    /// pick the first result (`0`). Pianobar reads each line in turn.
    public func createStationFromSearch(_ query: String) async throws {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await write("c\n")
        try await write("s\n")
        try await write("\(trimmed)\n")
        try await write("0\n")
    }
    public func deleteStation()           async throws { try await write("d\n") }
    public func renameStation(_ newName: String) async throws {
        try await write("r\(newName)\n")
    }
    /// Deprecated. Pianobar's FIFO has no absolute-volume command; `(` and
    /// `)` are increment/decrement only, so the previous "(<N>" syntax was
    /// just decrementing pianobar's volume one step per call. The app now
    /// drives macOS system output volume directly. This stub is kept so
    /// existing callers don't break.
    public func setVolume(_ v: Int) async throws {}
    public func quit() async throws { try await write("q\n") }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    /// How long to keep retrying the FIFO open while no reader is attached.
    /// Covers the window where the supervisor is respawning pianobar, without
    /// ever becoming an unbounded wait.
    private static let openTimeout: TimeInterval = 2.0
    private static let openRetryInterval: UInt64 = 50_000_000  // 50ms

    private func write(_ cmd: String) async throws {
        guard let data = cmd.data(using: .utf8) else { return }
        // pianobar reads its control FIFO in a loop that reopens the file each
        // time round, so the reader end legitimately disappears between
        // commands and a cached write handle goes stale with EPIPE. Drop the
        // handle and retry once against a fresh descriptor; only a second
        // failure is a real one.
        //
        // Dropping the handle also matters after pianobar dies and the
        // supervisor recreates the FIFO — previously the stale handle stayed
        // cached and every later command failed forever.
        for attempt in 0...1 {
            if handle == nil {
                try await openFIFO()
            }
            do {
                try handle!.write(contentsOf: data)
                return
            } catch {
                try? handle?.close()
                handle = nil
                if attempt == 1 { throw Error.writeFailed(error) }
            }
        }
    }

    private func openFIFO() async throws {
        // O_WRONLY alone blocks *indefinitely* on a FIFO with no reader. Since
        // this is an actor, one such call would wedge every later command
        // behind it — play/pause, skip, thumbs, station switching and the media
        // keys would all go permanently dead with no user feedback, and the app
        // would have to be force-quit.
        //
        // O_NONBLOCK instead fails immediately with ENXIO when pianobar isn't
        // reading. Retry briefly so a command issued while the supervisor is
        // respawning still lands, then give up — bounded, and `await` here
        // suspends rather than occupying a thread.
        let deadline = Date().addingTimeInterval(Self.openTimeout)
        while true {
            let fd = open(fifoPath, O_WRONLY | O_NONBLOCK)
            if fd >= 0 {
                // Writing to a FIFO whose reader (pianobar) has gone away
                // raises SIGPIPE, which by default terminates the process.
                // Suppress it per-descriptor so the write just fails with
                // EPIPE and the caller can react — a library shouldn't depend
                // on its host having changed the global signal disposition.
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                return
            }
            let err = errno
            // ENXIO is specifically "FIFO has no reader yet" — the only case
            // worth waiting on. Anything else (missing path, permissions) won't
            // fix itself.
            guard err == ENXIO, Date() < deadline else {
                throw Error.openFailed(String(cString: strerror(err)))
            }
            try? await Task.sleep(nanoseconds: Self.openRetryInterval)
        }
    }
}
