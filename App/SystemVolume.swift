import Foundation
import AppKit

/// Read and write the macOS system output volume via Apple Events.
/// Pianobar's FIFO has no absolute-volume command, so the in-app slider
/// drives system volume instead.
enum SystemVolume {
    /// Returns 0…100 for the current output volume, or nil on failure.
    static func read() -> Int? {
        let script = "output volume of (get volume settings)"
        return runAppleScript(script)
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Sets system output volume. Value clamped to 0…100.
    static func set(_ value: Int) {
        let v = max(0, min(100, value))
        _ = runAppleScript("set volume output volume \(v)")
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result?.stringValue
    }
}
