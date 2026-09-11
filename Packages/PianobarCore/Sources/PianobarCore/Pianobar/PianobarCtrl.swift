import Foundation

public actor PianobarCtrl {
    public enum Error: Swift.Error, LocalizedError {
        case openFailed(String)
        // Carries the underlying error rather than `errno`, which by the time a
        // Swift `FileHandle` throw is caught may already have been overwritten
        // by unrelated syscalls.
        case writeFailed(Swift.Error)

        public var errorDescription: String? {
            switch self {
            case .openFailed(let detail):
                return "Couldn't open pianobar's control channel: \(detail)"
            case .writeFailed(let underlying):
                return "Couldn't send the command to pianobar: \(underlying.localizedDescription)"
            }
        }
    }

    private let fifoPath: String
    private var handle: FileHandle?

    public init(fifoPath: String) {
        self.fifoPath = fifoPath
    }

    // pianobar has explicit `P` (play) and `S` (pause) alongside the `p`
    // toggle. Use the explicit ones: a blind toggle means the app's idea of
    // the play state is only ever a guess, and once that guess drifts — a lost
    // write, a pause from another source — every later toggle is inverted and
    // the transport button does the opposite of what it says. `P` and `S` are
    // idempotent, so they resynchronise instead of compounding the error.
    //
    // Known pianobar limitation (intentionally not worked around): while
    // paused, pianobar stops reading the Pandora audio stream. After a pause
    // longer than its ~15–30s audio buffer, the CDN connection goes idle and is
    // dropped (and/or the signed URL expires). On resume pianobar plays out the
    // buffered tail, hits EOF, treats it as end-of-track, and advances to the
    // next song. pianobar exposes no way to re-fetch the current song, so we
    // rely on its buffer and accept this — short pauses resume normally.
    public func play()          async throws { try await write("P\n") }
    public func pause()         async throws { try await write("S\n") }
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
    ///
    /// Sequence: `c` → "Create station from [s]ong or [a]rtist?" → "Create
    /// station from artist or title:" → "Select song:". See the note on
    /// `deleteStation` for why the first answer shares a line with `c`.
    public func createStationFromSearch(_ query: String) async throws {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await write("cs\n")
        try await write("\(trimmed)\n")
        try await write("0\n")
    }

    /// Deletes the *currently playing* station.
    ///
    /// pianobar answers `d` with `Really delete "<name>"? [yN]`, and the
    /// capital N means an empty answer declines. Sending `d\n` therefore never
    /// deleted anything — the newline was consumed as "no" — and left pianobar
    /// parked at the prompt, where it would swallow the user's next command.
    ///
    /// The `y` shares a line with the command because pianobar reads the
    /// command as a single character and then reads the *rest of that line* as
    /// the prompt's answer. `renameStation` below has always relied on the
    /// same behaviour, which is why it worked while this didn't.
    public func deleteStation() async throws { try await write("dy\n") }

    /// Renames the *currently playing* station. `r` is the command; the rest
    /// of the line answers pianobar's "New name:" prompt.
    public func renameStation(_ newName: String) async throws {
        try await write("r\(newName)\n")
    }
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
