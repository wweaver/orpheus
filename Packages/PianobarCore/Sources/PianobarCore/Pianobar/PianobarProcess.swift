import Foundation

public actor PianobarProcess {
    public enum Error: Swift.Error { case notRunning, spawnFailed(String) }

    public enum State: Equatable { case stopped, running, crashed }

    private let executablePath: String
    private let xdgConfigHome: String
    private let eventSocketPath: String
    private let logFileURL: URL?
    private var process: Process?
    private(set) var state: State = .stopped

    public init(executablePath: String, xdgConfigHome: String, eventSocketPath: String,
                logFileURL: URL? = nil) {
        self.executablePath = executablePath
        self.xdgConfigHome = xdgConfigHome
        self.eventSocketPath = eventSocketPath
        self.logFileURL = logFileURL
    }

    public func start() async throws {
        if state == .running { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executablePath)
        p.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "XDG_CONFIG_HOME": xdgConfigHome,
            "PIANOBAR_GUI_SOCK": eventSocketPath,
        ]
        // Pipe stdin from /dev/null so pianobar's interactive prompts never block.
        p.standardInput = FileHandle(forReadingAtPath: "/dev/null")

        // Capture stdout/stderr to the log file when configured; /dev/null otherwise.
        let logHandle: FileHandle
        if let url = logFileURL {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            logHandle = (try? FileHandle(forWritingTo: url))
                ?? FileHandle(forWritingAtPath: "/dev/null")!
            logHandle.seekToEndOfFile()
        } else {
            logHandle = FileHandle(forWritingAtPath: "/dev/null")!
        }
        p.standardOutput = logHandle
        p.standardError  = logHandle
        do {
            try p.run()
        } catch {
            throw Error.spawnFailed(String(describing: error))
        }
        process = p
        state = .running
    }

    public func stop() async throws {
        guard let p = process else { throw Error.notRunning }
        p.terminate()
        p.waitUntilExit()
        process = nil
        state = .stopped
    }
}
