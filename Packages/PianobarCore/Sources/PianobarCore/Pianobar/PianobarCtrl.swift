import Foundation

public actor PianobarCtrl {
    public enum Error: Swift.Error {
        case openFailed(String)
        case writeFailed(Int32)
    }

    private let fifoPath: String
    private var handle: FileHandle?

    public init(fifoPath: String) {
        self.fifoPath = fifoPath
    }

    public func play()          async throws { try write("p\n") }
    public func pause()         async throws { try write("p\n") } // pianobar toggles
    public func togglePlay()    async throws { try write("p\n") }
    public func next()          async throws { try write("n\n") }
    public func love()          async throws { try write("+\n") }
    public func ban()           async throws { try write("-\n") }
    public func tired()         async throws { try write("t\n") }
    public func bookmarkSong()  async throws { try write("b\n") }
    public func bookmarkArtist() async throws { try write("b\na\n") }

    public func switchStation(index: Int) async throws {
        try write("s\(index)\n")
    }

    public func createStationFromSong()   async throws { try write("c\n") }
    public func createStationFromArtist() async throws { try write("v\n") }
    public func deleteStation()           async throws { try write("d\n") }
    public func renameStation(_ newName: String) async throws {
        try write("r\(newName)\n")
    }
    public func setVolume(_ v: Int) async throws {
        let clamped = max(0, min(100, v))
        try write("(\(clamped)\n")
    }
    public func quit() async throws { try write("q\n") }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    private func write(_ cmd: String) throws {
        if handle == nil {
            // Opening a FIFO for writing blocks until a reader is present.
            // Use O_WRONLY; caller is responsible for the reader (pianobar).
            let fd = open(fifoPath, O_WRONLY)
            guard fd >= 0 else { throw Error.openFailed(String(cString: strerror(errno))) }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        guard let data = cmd.data(using: .utf8) else { return }
        do {
            try handle!.write(contentsOf: data)
        } catch {
            throw Error.writeFailed(errno)
        }
    }
}
