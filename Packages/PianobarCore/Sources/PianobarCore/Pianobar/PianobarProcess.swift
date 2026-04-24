import Foundation

public actor PianobarProcess {
    public enum Error: Swift.Error { case notRunning, spawnFailed(String) }

    public enum State: Equatable { case stopped, running, crashed }

    private let executablePath: String
    private let xdgConfigHome: String
    private let eventSocketPath: String
    private var process: Process?
    private(set) var state: State = .stopped

    public init(executablePath: String, xdgConfigHome: String, eventSocketPath: String) {
        self.executablePath = executablePath
        self.xdgConfigHome = xdgConfigHome
        self.eventSocketPath = eventSocketPath
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
        // Discard stdout/stderr to /dev/null for now. Plan 2 will pipe to log file.
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError  = FileHandle(forWritingAtPath: "/dev/null")
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
