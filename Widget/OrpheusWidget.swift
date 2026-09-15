import WidgetKit
import SwiftUI

struct OrpheusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct OrpheusProvider: TimelineProvider {
    func placeholder(in context: Context) -> OrpheusEntry {
        OrpheusEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (OrpheusEntry) -> Void) {
        // The gallery preview gets stock content rather than an empty shell when
        // Orpheus has never run.
        let snapshot = context.isPreview ? .placeholder : (WidgetStore.load() ?? .empty)
        completion(OrpheusEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OrpheusEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetStore.load() ?? .empty
        let entry = OrpheusEntry(date: now, snapshot: snapshot)

        // Orpheus pushes a reload whenever the song or play state changes, so
        // this schedule is only a backstop for the case where it can't — it
        // crashed, or was force-quit without its termination hook running.
        // Waking at the end of the current track keeps a finished song from
        // sitting there with a full progress bar.
        let fallback: Date
        if let range = snapshot.timerRange, range.upperBound > now {
            fallback = range.upperBound.addingTimeInterval(2)
        } else if snapshot.isPlaying, snapshot.isLive(at: now),
                  let end = snapshot.expectedTrackEnd {
            // The track has run out with no fresh snapshot behind it. Orpheus
            // may just be between songs, so look again when the grace period
            // lapses instead of waiting a quarter of an hour to notice it died.
            fallback = end.addingTimeInterval(WidgetSnapshot.abandonGrace + 2)
        } else {
            fallback = now.addingTimeInterval(15 * 60)
        }
        completion(Timeline(entries: [entry], policy: .after(fallback)))
    }
}

struct OrpheusWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: OrpheusEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(snapshot: entry.snapshot)
                // Artwork is the background rather than a subview so it reaches
                // the widget's rounded corners instead of stopping at the
                // content edge.
                .containerBackground(for: .widget) {
                    ArtworkView(url: WidgetStore.artworkURL(for: entry.snapshot), cornerRadius: 0)
                }
        case .systemLarge:
            LargeWidgetView(snapshot: entry.snapshot)
                .padding(14)
                .containerBackground(.fill.tertiary, for: .widget)
        default:
            MediumWidgetView(snapshot: entry.snapshot)
                .padding(14)
                .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

struct OrpheusWidget: Widget {
    let kind = "OrpheusNowPlaying"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OrpheusProvider()) { entry in
            OrpheusWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("Shows the current Pandora song and controls playback.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        // The small size puts artwork edge-to-edge under its own scrim, which
        // the default content margins would inset. Medium and large pad
        // themselves instead.
        .contentMarginsDisabled()
    }
}

@main
struct OrpheusWidgetBundle: WidgetBundle {
    var body: some Widget {
        OrpheusWidget()
    }
}

extension WidgetSnapshot {
    /// Orpheus has never written a snapshot, or has been signed out.
    static let empty = WidgetSnapshot(
        title: "",
        artist: "",
        album: "",
        stationName: "",
        isPlaying: false,
        progressSeconds: 0,
        durationSeconds: 0,
        rating: "unrated",
        artworkFile: nil,
        savedAt: Date(),
        appRunning: false
    )
}
