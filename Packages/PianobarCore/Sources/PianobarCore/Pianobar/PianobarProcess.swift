import Foundation
import Darwin

/// Atomically-tracked PID of the most recently spawned pianobar child. Used by
/// an `atexit` hook so ⌘Q / `NSApp.terminate(_:)` reliably kills pianobar even
/// though the Swift actor that owns it can't be awaited from a C callback.
public final class PianobarPIDRegistry: @unchecked Sendable {
    public static let shared = PianobarPIDRegistry()
    private let lock = NSLock()
    private var pid: pid_t = 0

    private init() {
        atexit {
            let p = PianobarPIDRegistry.shared.take()
            if p > 0 { _ = kill(p, SIGTERM) }
        }
    }

    public func set(_ newPid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pid = newPid
    }

    public func clear(_ oldPid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        if pid == oldPid { pid = 0 }
    }

    /// Read and zero in one shot so the atexit handler is idempotent.
    private func take() -> pid_t {
        lock.lock(); defer { lock.unlock() }
        let p = pid; pid = 0; return p
    }
}

public actor PianobarProcess {
    public enum Error: Swift.Error { case notRunning, spawnFailed(String) }

    public enum State: Equatable { case stopped, running, crashed }

    private let executablePath: String
    private let xdgConfigHome: String
    private let eventSocketPath: String
    private let logFileURL: URL?
    private let eventDebugLogURL: URL?
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
                eventDebugLogURL: URL? = nil,
                supervisorBackoff: [TimeInterval] = [1, 2, 4, 8, 16, 30]) {
        self.executablePath = executablePath
        self.xdgConfigHome = xdgConfigHome
        self.eventSocketPath = eventSocketPath
        self.logFileURL = logFileURL
        self.eventDebugLogURL = eventDebugLogURL
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
        let pid = p.processIdentifier
        p.terminate()
        p.waitUntilExit()
        PianobarPIDRegistry.shared.clear(pid)
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
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "XDG_CONFIG_HOME": xdgConfigHome,
            "PIANOBAR_GUI_SOCK": eventSocketPath,
        ]
        if let url = eventDebugLogURL {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            env["PIANOBAR_GUI_EVENT_LOG"] = url.path
        }
        p.environment = env
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
        PianobarPIDRegistry.shared.set(p.processIdentifier)
    }

    private func waitForExit() async {
        guard let p = process else { return }
        let pid = p.processIdentifier
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
        PianobarPIDRegistry.shared.clear(pid)
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
