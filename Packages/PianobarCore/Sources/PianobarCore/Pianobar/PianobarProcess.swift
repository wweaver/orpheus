import Foundation
import Darwin

/// Lock-free mirrors of the child pid and the exit policy.
///
/// A signal handler may only call async-signal-safe functions, which rules out
/// taking the registry's `NSLock`. `kill(2)` *is* async-signal-safe, so the
/// handler reads these instead. `sig_atomic_t` is the type the C standard
/// guarantees can be read and written atomically with respect to signals.
nonisolated(unsafe) private var signalSafePianobarPID: sig_atomic_t = 0
nonisolated(unsafe) private var signalSafeKeepAlive: sig_atomic_t = 0

/// Signals whose default disposition terminates us, and which we can catch.
/// SIGKILL is deliberately absent: it cannot be caught, which is why
/// `reapOrphanIfAny` exists as the backstop.
private let terminatingSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP, SIGQUIT]

/// Atomically-tracked PID of the most recently spawned pianobar child.
///
/// Cleanup runs from two places, because neither covers every exit:
///   * an `atexit` hook, for a normal quit (⌘Q / `NSApp.terminate`);
///   * signal handlers, because `atexit` does *not* run on SIGTERM, SIGINT or
///     SIGHUP — so `killall Orpheus`, a force quit, a logout, or a parent
///     shell going away all used to leave pianobar playing with no UI and no
///     way to control it short of `killall pianobar`.
///
/// A `kill -9` or a hard crash can't be intercepted at all; `reapOrphanIfAny`
/// cleans up after those on the next launch.
public final class PianobarPIDRegistry: @unchecked Sendable {
    public enum ExitAction: Sendable { case kill, keepAlive }

    public static let shared = PianobarPIDRegistry()
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var action: ExitAction = .kill

    private init() {
        atexit {
            let (p, a) = PianobarPIDRegistry.shared.snapshot()
            if p > 0, a == .kill {
                _ = kill(p, SIGTERM)
            }
            // .keepAlive: leave the child running; a future launch will
            // reattach via the pidfile.
        }
        installSignalHandlers()
    }

    private func installSignalHandlers() {
        for signo in terminatingSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { caught in
                // Async-signal-safe only: no locks, no allocation, no Swift
                // runtime calls beyond these.
                if signalSafeKeepAlive == 0 {
                    let pid = signalSafePianobarPID
                    if pid > 0 { _ = kill(pid_t(pid), SIGTERM) }
                }
                // Re-raise with the default handler so our exit status still
                // reflects the signal that killed us.
                signal(caught, SIG_DFL)
                raise(caught)
            }
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(signo, &action, nil)
        }
    }

    public func set(_ newPid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pid = newPid
        signalSafePianobarPID = sig_atomic_t(newPid)
    }

    public func clear(_ oldPid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        if pid == oldPid {
            pid = 0
            signalSafePianobarPID = 0
        }
    }

    public func setExitAction(_ action: ExitAction) {
        lock.lock(); defer { lock.unlock() }
        self.action = action
        signalSafeKeepAlive = (action == .keepAlive) ? 1 : 0
    }

    private func snapshot() -> (pid_t, ExitAction) {
        lock.lock(); defer { lock.unlock() }
        return (pid, action)
    }
}

/// One-shot atomic latch. `claim()` returns true exactly once, no matter how
/// many threads race it — used to guarantee a `CheckedContinuation` is resumed
/// by only one of two competing callbacks.
final class ResumeLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Lightweight pidfile helper. Writes and reads a single integer pid at a
/// caller-chosen path. Used to let a later app launch discover a pianobar
/// that was deliberately left running (see `Prefs.Keys.keepPianobarAlive`).
public enum PianobarPidFile {
    public static func write(_ pid: pid_t, to path: String) {
        try? "\(pid)".write(toFile: path, atomically: true, encoding: .utf8)
    }

    public static func read(at path: String) -> pid_t? {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else { return nil }
        return pid
    }

    public static func clear(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Returns a pid if the file points to a process that is alive, else nil.
    public static func existingLivePid(at path: String) -> pid_t? {
        guard let pid = read(at: path) else { return nil }
        return kill(pid, 0) == 0 ? pid : nil
    }

    /// Absolute path of the executable a pid is running, or nil.
    ///
    /// Pids are recycled, so "this pid is alive" is not evidence that it's
    /// still *our* pianobar — by the time we look, the number could belong to
    /// any process on the system. Anything that goes on to kill the pid must
    /// confirm identity first.
    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Kill a pianobar left behind by a previous run of the app.
    ///
    /// The signal handlers cover an ordinary kill, but `SIGKILL` and hard
    /// crashes can't be intercepted at all, so a pianobar can still be
    /// orphaned — playing audio with no UI and no way to control it. Clean it
    /// up at the next launch, but only once we've confirmed the pid really is
    /// the pianobar binary we spawn and not a recycled pid.
    ///
    /// Returns true if something was killed.
    @discardableResult
    public static func reapOrphan(at path: String, expecting executablePath: String) -> Bool {

        guard let pid = existingLivePid(at: path) else {
            clear(at: path)
            return false
        }
        guard let running = Self.executablePath(of: pid),
              isPianobar(running, expecting: executablePath)
        else {
            // Stale file pointing at an unrelated process. Drop the file, but
            // do not touch the process.
            clear(at: path)
            return false
        }
        _ = kill(pid, SIGTERM)
        clear(at: path)
        return true
    }

    /// Whether a running executable path is the pianobar we spawn.
    ///
    /// Compares canonical paths, because `proc_pidpath` resolves symlinks and
    /// the path we launch usually *is* one — Homebrew's
    /// `/opt/homebrew/bin/pianobar` points into `Cellar/pianobar/<version>/`,
    /// so a naive string compare never matched and the orphan survived.
    ///
    /// Falls back to the executable name, which also covers a pianobar left
    /// over from before a Homebrew upgrade moved the Cellar path. The pid came
    /// from a pidfile only we write, inside our own Application Support
    /// directory, so "recycled pid that also happens to be running pianobar"
    /// is not a case worth protecting against — and killing it would be right
    /// anyway.
    private static func isPianobar(_ running: String, expecting expected: String) -> Bool {
        let canonical = { (path: String) -> String in
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        if canonical(running) == canonical(expected) { return true }
        return URL(fileURLWithPath: running).lastPathComponent
            == URL(fileURLWithPath: expected).lastPathComponent
    }
}

public actor PianobarProcess {
    public enum Error: Swift.Error, LocalizedError {
        case notRunning
        case spawnFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notRunning:   return "pianobar isn't running."
            case .spawnFailed(let detail): return detail
            }
        }
    }

    public enum State: Equatable { case stopped, running, crashed }

    private let executablePath: String
    private let xdgConfigHome: String
    private let eventSocketPath: String
    private let logFileURL: URL?
    private let eventDebugLogURL: URL?
    private let pidFilePath: String?
    private let supervisorBackoff: [TimeInterval]
    private let healthyUptime: TimeInterval
    private var process: Process?
    private(set) var state: State = .stopped
    private var shouldStopSupervising = false
    private var supervisorTask: Task<Void, Never>?

    private let failureContinuation: AsyncStream<Void>.Continuation
    public nonisolated let supervisorFailures: AsyncStream<Void>

    /// Default backoff: 1, 2, 4, 8, 16, 30s. After 5 consecutive crashes, give up.
    /// `healthyUptime` is how long a process must stay up for the crash to be
    /// treated as isolated rather than part of a loop, which refunds the
    /// backoff budget.
    public init(executablePath: String,
                xdgConfigHome: String,
                eventSocketPath: String,
                logFileURL: URL? = nil,
                eventDebugLogURL: URL? = nil,
                pidFilePath: String? = nil,
                supervisorBackoff: [TimeInterval] = [1, 2, 4, 8, 16, 30],
                healthyUptime: TimeInterval = 60) {
        self.executablePath = executablePath
        self.xdgConfigHome = xdgConfigHome
        self.eventSocketPath = eventSocketPath
        self.logFileURL = logFileURL
        self.eventDebugLogURL = eventDebugLogURL
        self.pidFilePath = pidFilePath
        self.supervisorBackoff = supervisorBackoff
        self.healthyUptime = healthyUptime

        var cont: AsyncStream<Void>.Continuation!
        self.supervisorFailures = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { cont = $0 }
        self.failureContinuation = cont
    }

    public func start() async throws {
        // `state` only becomes .running inside the supervisor task, so checking
        // it alone lets two start() calls made before the first task is
        // scheduled both pass — the second would overwrite `supervisorTask` and
        // leave the first as an orphan spawning its own pianobar. Gate on the
        // task handle instead.
        if supervisorTask != nil || state == .running { return }
        shouldStopSupervising = false
        supervisorTask = Task {
            await self.superviseLoop()
            // Loop ended (gave up, or stop() asked it to). Release the handle so
            // a later start() on this instance isn't blocked by a dead task.
            self.clearSupervisorTaskIfFinished()
        }
    }

    private func clearSupervisorTaskIfFinished() {
        if shouldStopSupervising { supervisorTask = nil }
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
        if let path = pidFilePath { PianobarPidFile.clear(at: path) }
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
            let startedAt = Date()
            // Block until the process exits.
            await waitForExit()
            if shouldStopSupervising { return }
            // The budget is meant to stop a crash *loop*, not to cap total
            // crashes for the life of the session. Without this reset a session
            // that plays fine for hours and hits one transient crash per hour
            // exhausts the budget and permanently gives up.
            if Date().timeIntervalSince(startedAt) >= healthyUptime {
                failureIndex = 0
            }
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
        p.standardInput = FileHandle.nullDevice
        let logHandle: FileHandle
        if let url = logFileURL {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            logHandle = (try? FileHandle(forWritingTo: url)) ?? .nullDevice
            logHandle.seekToEndOfFile()
        } else {
            logHandle = .nullDevice
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
        if let path = pidFilePath {
            PianobarPidFile.write(p.processIdentifier, to: path)
        }
    }

    private func waitForExit() async {
        guard let p = process else { return }
        let pid = p.processIdentifier
        // `terminationHandler` fires on Foundation's own queue, so it can race
        // the `!p.isRunning` fallback below: if the process exits in the window
        // between the two, *both* paths run. Resuming a CheckedContinuation
        // twice traps and takes the whole app down — which is exactly the
        // fast-crash case the supervisor exists to handle. Clearing the handler
        // afterwards can't unwind one that already fired, so gate on an atomic
        // latch instead and let whichever path wins resume exactly once.
        let latch = ResumeLatch()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in
                if latch.claim() { cont.resume() }
            }
            // If the process already exited before we installed the handler,
            // terminationHandler never fires — resume here instead.
            if !p.isRunning, latch.claim() {
                cont.resume()
            }
        }
        p.terminationHandler = nil
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
