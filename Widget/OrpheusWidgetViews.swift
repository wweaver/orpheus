import SwiftUI
import WidgetKit
import AppKit

// MARK: - Pieces

/// Cover art loaded straight off disk.
///
/// Synchronous on purpose: a widget is rendered in one pass on the system's
/// schedule, so there is no second chance to fill in an async image. WidgetBridge
/// guarantees the bytes are already in the container before it names the file in
/// a snapshot.
struct ArtworkView: View {
    let url: URL?
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A transport control. Rendered as plain glyph-on-nothing so it reads as part
/// of the artwork rather than as chrome.
struct TransportButton: View {
    let systemName: String
    let command: OrpheusCommand
    var size: CGFloat = 13
    var prominent: Bool = false
    var tint: Color?
    let label: String

    var body: some View {
        Button(intent: OrpheusCommandIntent(command)) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: prominent ? .semibold : .regular))
                .foregroundStyle(tint ?? .primary)
                .frame(width: size + 12, height: size + 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Playback position. Uses SwiftUI's timer-driven forms while playing so the bar
/// and the clock keep moving between widget reloads — the snapshot is only
/// rewritten on song and play-state changes, not once a second.
struct ProgressStrip: View {
    let snapshot: WidgetSnapshot
    var showTimes: Bool = true
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let range = snapshot.animatedRange() {
                    ProgressView(timerInterval: range, countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                } else {
                    ProgressView(
                        value: Double(snapshot.elapsed()),
                        total: Double(max(1, snapshot.durationSeconds))
                    )
                }
            }
            .progressViewStyle(.linear)
            .tint(tint)

            if showTimes {
                HStack {
                    if let range = snapshot.animatedRange() {
                        // Counts up from the instant the track was at 0:00.
                        Text(range.lowerBound, style: .timer)
                    } else {
                        Text(Self.clock(snapshot.elapsed()))
                    }
                    Spacer()
                    Text(Self.clock(snapshot.durationSeconds))
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
    }

    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Shown instead of the transport when Orpheus isn't running. Its buttons would
/// post notifications into an empty room, so offer the one thing that helps:
/// clicking anywhere on a widget launches the containing app.
struct AppStoppedNote: View {
    var compact: Bool = false

    var body: some View {
        Label(compact ? "Not running" : "Open Orpheus to play", systemImage: "bolt.slash")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

// MARK: - Small

/// Square. Art is the whole widget; text and transport ride on a scrim over the
/// bottom third, which is the only way to fit a readable title, an artist, and
/// two controls into this footprint.
struct SmallWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        ZStack(alignment: .bottom) {
            ArtworkView(url: WidgetStore.artworkURL(for: snapshot), cornerRadius: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.55), .black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 92)

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.hasSong ? snapshot.title : "Nothing playing")
                    .font(.caption).fontWeight(.semibold)
                    .lineLimit(1)
                Text(snapshot.artist)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)

                if snapshot.isLive() {
                    HStack(spacing: 2) {
                        TransportButton(
                            systemName: snapshot.isPlaying ? "pause.fill" : "play.fill",
                            command: .togglePlay,
                            size: 14,
                            prominent: true,
                            label: snapshot.isPlaying ? "Pause" : "Play"
                        )
                        TransportButton(
                            systemName: "forward.fill",
                            command: .next,
                            size: 14,
                            label: "Next song"
                        )
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 1)
                } else {
                    AppStoppedNote(compact: true).padding(.top, 3)
                }

                // The only size with no room for a clock, so the bar alone
                // carries position. White rather than accent: it sits on the
                // artwork scrim, where the accent colour can land on top of a
                // cover it clashes with.
                if snapshot.durationSeconds > 0 {
                    ProgressStrip(snapshot: snapshot, showTimes: false, tint: .white)
                        .padding(.top, 5)
                }
            }
            // White regardless of appearance: this text always sits on a dark
            // scrim over the artwork, never on the widget background.
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Medium

/// Wide. Art keeps its square on the leading edge and the remaining width takes
/// the metadata, a progress strip, and the full transport including ratings.
struct MediumWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: WidgetStore.artworkURL(for: snapshot))
                .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 0) {
                // The station is a heading for the pane, so it stays pinned to
                // the top.
                if !snapshot.stationName.isEmpty {
                    Text(snapshot.stationName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Matched spacers above and below, so the song sits centred in
                // whatever room is left between the station and the progress
                // strip rather than hanging off the heading.
                Spacer(minLength: 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.hasSong ? snapshot.title : "Nothing playing")
                        .font(.headline)
                        .lineLimit(1)
                    Text(snapshot.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if snapshot.durationSeconds > 0 {
                    ProgressStrip(snapshot: snapshot)
                }

                if snapshot.isLive() {
                    TransportRow(snapshot: snapshot, includeTired: false)
                        .padding(.top, 4)
                } else {
                    AppStoppedNote().padding(.top, 6)
                }
            }
        }
    }
}

// MARK: - Large

/// Tall. Art gets the top half at full width, then metadata with the album line
/// that the smaller sizes have to drop, and every control including "tired of
/// this song".
struct LargeWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !snapshot.stationName.isEmpty {
                Text(snapshot.stationName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.bottom, 6)
            }

            // Priority, not a Spacer-mediated share. Without it the flexible
            // gaps won the negotiation and the square settled at under half
            // the widget's width, which wastes the one size that has room to
            // show the cover properly.
            ArtworkView(url: WidgetStore.artworkURL(for: snapshot), cornerRadius: 10)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
                .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.hasSong ? snapshot.title : "Nothing playing")
                    .font(.headline)
                    .lineLimit(1)
                Text(snapshot.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !snapshot.album.isEmpty, snapshot.album != snapshot.title {
                    Text(snapshot.album)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            if snapshot.durationSeconds > 0 {
                ProgressStrip(snapshot: snapshot)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            }

            if snapshot.isLive() {
                TransportRow(snapshot: snapshot, includeTired: true)
            } else {
                AppStoppedNote()
            }
        }
    }
}

// MARK: - Transport

/// Ratings, play/pause and skip in one row. Thumb glyphs fill and tint to match
/// the player window's own transport, so a song loved in the app reads as loved
/// here.
struct TransportRow: View {
    let snapshot: WidgetSnapshot
    let includeTired: Bool

    private var isLoved: Bool { snapshot.rating == "loved" }
    private var isBanned: Bool { snapshot.rating == "banned" }

    var body: some View {
        HStack(spacing: 2) {
            TransportButton(
                systemName: snapshot.isPlaying ? "pause.fill" : "play.fill",
                command: .togglePlay,
                size: 15,
                prominent: true,
                label: snapshot.isPlaying ? "Pause" : "Play"
            )
            TransportButton(
                systemName: "forward.fill",
                command: .next,
                size: 15,
                label: "Next song"
            )

            Spacer(minLength: 0)

            TransportButton(
                systemName: isBanned ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                command: .ban,
                tint: isBanned ? .accentColor : nil,
                label: "Dislike"
            )
            TransportButton(
                systemName: isLoved ? "hand.thumbsup.fill" : "hand.thumbsup",
                command: .love,
                tint: isLoved ? .accentColor : nil,
                label: "Like"
            )
            if includeTired {
                TransportButton(
                    systemName: "moon.zzz",
                    command: .tired,
                    label: "Tired of this song"
                )
            }
        }
    }
}
