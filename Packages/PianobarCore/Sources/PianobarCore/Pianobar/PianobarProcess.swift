import Foundation

public actor PianobarProcess {
    public enum Error: Swift.Error { case notRunning, spawnFailed(String) }

    public enum State: Equatable { case stopped, running, crashed }

    private let executablePath: String
    private let xdgConfigHome: String
    private let eventSocketPath: String
    private let logFileURL: URL?
    private let supervisorBackoff: [TimeInterval]
    private var process: Process?
    private(set) var state: State = .stopped
    private var shouldStopSupervising = false
    private var supervisorTask: Task<Void, Never>?

    private let failureContinuation: AsyncStream<Void>.Continuation
    public nonisolated let supervisorFailures: AsyncStream<Void>

    /// Default backoff: 1, 2, 4, 8, 16, 30s. After 5 consecutive crashes, give up.
    public init(executablePath: String,
                xdgConfigHome: String,
                eventSocketPath: String,
                logFileURL: URL? = nil,
                supervisorBackoff: [TimeInterval] = [1, 2, 4, 8, 16, 30]) {
        self.executablePath = executablePath
        self.xdgConfigHome = xdgConfigHome
        self.eventSocketPath = eventSocketPath
        self.logFileURL = logFileURL
        self.supervisorBackoff = supervisorBackoff

        var cont: AsyncStream<Void>.Continuation!
        self.supervisorFailures = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { cont = $0 }
        self.failureContinuation = cont
    }

    public func start() async throws {
        if state == .running { return }
        shouldStopSupervising = false
        supervisorTask = Task {
            await self.superviseLoop()
        }
    }

    public func stop() async throws {
        shouldStopSupervising = true
        supervisorTask?.cancel()
        supervisorTask = nil
        guard let p = process else { state = .stopped; return }
        p.terminate()
        p.waitUntilExit()
        process = nil
        state = .stopped
    }

    private func superviseLoop() async {
        var failureIndex = 0
        while !shouldStopSupervising {
            do {
                try spawn()
            } catch {
                await handleFailure(&failureIndex)
                continue
            }
            state = .running
            // Block until the process exits.
            await waitForExit()
            if shouldStopSupervising { return }
            // Unexpected exit.
            await handleFailure(&failureIndex)
        }
    }

    private func spawn() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executablePath)
        p.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "XDG_CONFIG_HOME": xdgConfigHome,
            "PIANOBAR_GUI_SOCK": eventSocketPath,
        ]
        p.standardInput = FileHandle(forReadingAtPath: "/dev/null")
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
        p.standardError = logHandle
        do {
            try p.run()
        } catch {
            throw Error.spawnFailed(String(describing: error))
        }
        process = p
    }

    private func waitForExit() async {
        guard let p = process else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in
                cont.resume()
            }
            // If the process already exited before we set the handler, terminationHandler
            // won't fire. Fall back to a detached wait.
            if !p.isRunning {
                p.terminationHandler = nil
                cont.resume()
            }
        }
        process = nil
    }

    private func handleFailure(_ failureIndex: inout Int) async {
        if failureIndex >= supervisorBackoff.count {
            state = .crashed
            failureContinuation.yield(())
            shouldStopSupervising = true
            return
        }
        let delay = supervisorBackoff[failureIndex]
        failureIndex += 1
        let nanos = UInt64(max(delay, 0) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
    }
}
