import Foundation
import os

/// State and command plumbing shared between Orpheus and its widget extension.
///
/// The two live in different processes with different sandbox rules: the app
/// is unsandboxed (it spawns and supervises pianobar), the widget extension is
/// sandboxed because WidgetKit requires it. An App Group container is the one
/// piece of filesystem both can reach, so it carries the state; commands go the
/// other way as distributed notifications.
///
/// Deliberately free of any PianobarCore import. The widget only needs a flat
/// snapshot, and keeping the dependency out means the extension doesn't link
/// process-management code it can't legally run anyway.
enum OrpheusShared {
    /// Distributed notification carrying a widget button press back to the app.
    /// The command's raw value travels as the notification's `object`.
    static let commandNotification = Notification.Name("org.pianobar-gui.widget-command")

    static let log = Logger(subsystem: "org.pianobar-gui.PianobarGUI", category: "widget")

    /// The real login home, not the sandbox's idea of it.
    ///
    /// Inside the widget extension `NSHomeDirectory()` and
    /// `.applicationSupportDirectory` both resolve to the extension's own
    /// container. `getpwuid` reports the actual account home in either process,
    /// which is what lets one path expression work on both sides.
    private static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    /// Where the app publishes widget state.
    ///
    /// Deliberately *not* an App Group container, which is the obvious choice
    /// and does not work here. Orpheus signs with an untrusted self-signed
    /// certificate and no Developer Team, so `secinitd` brings the extension's
    /// sandbox up as `signer:none` and refuses to map any group container: the
    /// group path still resolves, but every read off it is denied. Sandbox
    /// *temporary exceptions* are granted from the entitlement itself and
    /// don't care who signed it, so the extension gets a read-only
    /// home-relative exception for this directory instead. Keep this in sync
    /// with Widget/OrpheusWidget.entitlements.
    static var sharedDirectory: URL {
        realHome.appendingPathComponent(
            "Library/Application Support/PianobarGUI/Widget", isDirectory: true)
    }
}

// MARK: - Commands

/// The subset of pianobar controls the widget exposes. Raw values cross the
/// process boundary, so they're stable strings rather than ordinals.
enum OrpheusCommand: String {
    case togglePlay
    case next
    case love
    case ban
    case tired
}

// MARK: - Snapshot

/// Everything the widget draws, flattened and self-contained.
struct WidgetSnapshot: Codable, Equatable {
    var title: String
    var artist: String
    var album: String
    var stationName: String
    var isPlaying: Bool
    /// Progress at the moment `savedAt` was taken, not "now" — see `elapsed(at:)`.
    var progressSeconds: Int
    var durationSeconds: Int
    /// Mirrors PianobarCore's `Rating.rawValue`; kept as a string so this file
    /// stays independent of the package.
    var rating: String
    /// Filename inside the container, not a path, so the value survives the
    /// container being resolved differently in either process.
    var artworkFile: String?
    var savedAt: Date
    /// False once Orpheus has quit cleanly. The widget's buttons are useless
    /// without the app — pianobar is its child process — so the UI needs to
    /// say so rather than silently dropping presses.
    var appRunning: Bool

    static let placeholder = WidgetSnapshot(
        title: "Headlights",
        artist: "Alex Warren",
        album: "Headlights",
        stationName: "How Do I Say Goodbye Radio",
        isPlaying: true,
        progressSeconds: 22,
        durationSeconds: 173,
        rating: "unrated",
        artworkFile: nil,
        savedAt: Date(),
        appRunning: true
    )

    /// Seconds played as of `date`.
    ///
    /// The app only rewrites the snapshot on song, station, and play-state
    /// changes — rewriting once a second would burn WidgetKit's reload budget
    /// for nothing — so a playing track's progress has to be extrapolated from
    /// how long ago the snapshot was taken. A paused track's doesn't move.
    func elapsed(at date: Date = Date()) -> Int {
        guard isPlaying else { return progressSeconds }
        let drift = Int(date.timeIntervalSince(savedAt))
        return min(durationSeconds, progressSeconds + max(0, drift))
    }

    /// Wall-clock instant this track was (or would have been) at 0:00, so
    /// SwiftUI's `ProgressView(timerInterval:)` and `Text(timerInterval:)` can
    /// animate without the widget being reloaded. Nil when paused, where there
    /// is nothing to animate.
    var timerRange: ClosedRange<Date>? {
        guard isPlaying, durationSeconds > 0 else { return nil }
        let start = savedAt.addingTimeInterval(-Double(progressSeconds))
        let end = start.addingTimeInterval(Double(durationSeconds))
        guard end > start else { return nil }
        return start...end
    }

    /// How long past a track's expected end we keep believing the app is there.
    /// Generous, because a slow station switch or a stalled Pandora request can
    /// legitimately leave a gap between songs.
    static let abandonGrace: TimeInterval = 120

    /// When this snapshot's track should have finished playing.
    var expectedTrackEnd: Date? {
        guard durationSeconds > 0 else { return nil }
        return savedAt.addingTimeInterval(Double(durationSeconds - progressSeconds))
    }

    /// Whether Orpheus is still there to receive a button press.
    ///
    /// `appRunning` alone isn't enough: it's cleared by the termination hook,
    /// which a crash or `kill -9` never reaches. But the app republishes on
    /// every song change, so while playing a snapshot should never outlive its
    /// own track by much — if it has, the app went away without saying so and
    /// the transport would be posting notifications into an empty room.
    func isLive(at date: Date = Date()) -> Bool {
        guard appRunning else { return false }
        guard isPlaying, let end = expectedTrackEnd else { return true }
        return date.timeIntervalSince(end) <= Self.abandonGrace
    }

    /// Range for the timer-driven bar and clock, or nil when there's nothing to
    /// animate. Withheld once the app looks gone: `Text(_:style: .timer)` counts
    /// up without bound, so with no reload coming it would sail past the track
    /// length and keep going.
    func animatedRange(at date: Date = Date()) -> ClosedRange<Date>? {
        isLive(at: date) ? timerRange : nil
    }

    var hasSong: Bool { !title.isEmpty }
}

// MARK: - Store

enum WidgetStore {
    private static let snapshotFile = "widget-snapshot.json"

    static func save(_ snapshot: WidgetSnapshot) {
        let dir = OrpheusShared.sharedDirectory
        guard let data = try? JSONEncoder().encode(snapshot) else {
            OrpheusShared.log.error("widget snapshot could not be encoded")
            return
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(snapshotFile), options: .atomic)
        } catch {
            OrpheusShared.log.error("widget snapshot not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func load() -> WidgetSnapshot? {
        let file = OrpheusShared.sharedDirectory.appendingPathComponent(snapshotFile)
        do {
            return try JSONDecoder().decode(WidgetSnapshot.self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            // Normal until Orpheus has run once; the views fall back to `.empty`.
            return nil
        } catch {
            OrpheusShared.log.error(
                "snapshot unreadable at \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Artwork

    /// Cover art is written out as bytes rather than left as a URL for the
    /// widget to fetch. A widget extension is woken briefly and on
    /// the system's terms; making it do network I/O means blank art on every
    /// cold render. The app already has the image.
    static func artworkURL(for snapshot: WidgetSnapshot) -> URL? {
        guard let file = snapshot.artworkFile else { return nil }
        let url = OrpheusShared.sharedDirectory.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Stable, content-derived name so an unchanged cover doesn't churn the
    /// file (and so WidgetKit isn't handed a path whose contents changed under
    /// it). Returns the filename to record in the snapshot.
    static func writeArtwork(_ data: Data, token: String) -> String? {
        let dir = OrpheusShared.sharedDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "art-\(Insecure64.hash(token)).jpg"
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        }
        pruneArtwork(keeping: name, in: dir)
        return name
    }

    /// The directory is ours alone and only ever holds one live cover, so
    /// anything else is from a previous song.
    private static func pruneArtwork(keeping name: String, in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for entry in entries where entry.hasPrefix("art-") && entry != name {
            try? fm.removeItem(at: dir.appendingPathComponent(entry))
        }
    }
}

/// Tiny non-cryptographic hash (FNV-1a). Only used to turn a cover-art URL into
/// a short, filesystem-safe, stable filename — nothing depends on it being
/// collision-resistant.
private enum Insecure64 {
    static func hash(_ string: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(h, radix: 36)
    }
}
