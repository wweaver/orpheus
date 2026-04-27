import Foundation
import SwiftUI
import PianobarCore

struct NowPlayingView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    var windowSize: CGSize = .zero

    private var showArt: Bool {
        windowSize.height >= 430
    }
    private var showHeader: Bool {
        windowSize.height >= 190
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                if showArt {
                    albumArt
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 240)
                }

                if showHeader {
                    if let song = state.currentSong {
                        songTitle(song)
                        artistButton(song)
                        Link(song.album, destination: song.albumDetailURL ?? pandoraAlbumURL(for: song))
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .help("Open album on Pandora")
                    } else {
                        Text("Not playing").foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    transportButton(systemName: state.isPlaying ? "pause.fill" : "play.fill") {
                        Task { try? await ctrl.togglePlay(); state.setPlaying(!state.isPlaying) }
                    }
                    transportButton(systemName: "forward.fill") {
                        Task { try? await ctrl.next() }
                    }
                    transportButton(systemName: "hand.thumbsdown") {
                        Task { try? await ctrl.ban() }
                    }
                    transportButton(systemName: "hand.thumbsup") {
                        Task { try? await ctrl.love() }
                    }
                }

                progressBar
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
    }

    private func artistButton(_ song: SongInfo) -> some View {
        Button {
            openArtist(song)
        } label: {
            Text(song.artist)
                .lineLimit(1)
        }
        .font(.subheadline)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Open artist on Pandora")
    }

    private func openArtist(_ song: SongInfo) {
        if let artistDetailURL = song.artistDetailURL {
            openURL(artistDetailURL)
            return
        }

        Task {
            guard let artistURL = await resolvePandoraArtistURL(for: song) else { return }
            await MainActor.run {
                openURL(artistURL)
            }
        }
    }

    private func transportButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var progressBar: some View {
        if let song = state.currentSong, song.durationSeconds > 0 {
            VStack(spacing: 4) {
                ProgressView(
                    value: Double(min(state.progressSeconds, song.durationSeconds)),
                    total: Double(song.durationSeconds)
                )
                HStack {
                    Text(format(state.progressSeconds))
                    Spacer()
                    Text(format(song.durationSeconds))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
        }
    }

    private func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @ViewBuilder
    private func songTitle(_ song: SongInfo) -> some View {
        if let detailURL = song.detailURL {
            Link(song.title, destination: detailURL)
                .font(.headline).bold()
                .buttonStyle(.plain)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .help("Open song on Pandora")
        } else {
            Text(song.title)
                .font(.headline).bold()
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }

    private func pandoraAlbumURL(for song: SongInfo) -> URL {
        let slugs = pandoraSlugs(from: song.detailURL)
        let artistSlug = slugs.artist ?? pandoraSlug(for: song.artist)
        let albumSlug = slugs.album ?? pandoraSlug(for: song.album)
        return pandoraURL(pathComponents: ["artist", artistSlug, albumSlug])
    }

    private func pandoraSlugs(from detailURL: URL?) -> (artist: String?, album: String?) {
        guard
            let detailURL,
            let host = detailURL.host?.lowercased(),
            host == "pandora.com" || host.hasSuffix(".pandora.com")
        else {
            return (nil, nil)
        }

        let pathComponents = detailURL.path
            .split(separator: "/")
            .map(String.init)
        guard pathComponents.first == "artist" else { return (nil, nil) }

        return (
            pathComponents.indices.contains(1) ? pathComponents[1] : nil,
            pathComponents.indices.contains(2) ? pathComponents[2] : nil
        )
    }

    private func pandoraURL(pathComponents: [String]) -> URL {
        let nonEmptyComponents = pathComponents.filter { !$0.isEmpty }
        guard nonEmptyComponents.count > 1 else {
            return URL(string: "https://www.pandora.com")!
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.pandora.com"
        components.path = "/" + nonEmptyComponents.joined(separator: "/")
        return components.url ?? URL(string: "https://www.pandora.com")!
    }

    private func pandoraSlug(for text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "&", with: " and ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()

        let allowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        var slug = ""
        var previousWasSeparator = false

        for scalar in normalized.unicodeScalars {
            if allowedScalars.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                slug.append("-")
                previousWasSeparator = true
            }
        }

        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func resolvePandoraArtistURL(for song: SongInfo) async -> URL? {
        for sourceURL in artistResolutionSourceURLs(for: song) {
            guard let html = await fetchString(from: sourceURL) else { continue }
            if let artistURL = pandoraArtistURL(in: html, for: song) {
                return artistURL
            }
        }
        return nil
    }

    private func artistResolutionSourceURLs(for song: SongInfo) -> [URL] {
        var urls = [URL]()
        if let detailURL = song.detailURL {
            urls.append(detailURL)
        }
        if let albumDetailURL = song.albumDetailURL {
            urls.append(albumDetailURL)
        } else if !song.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            urls.append(pandoraAlbumURL(for: song))
        }
        return urls
    }

    private func fetchString(from url: URL) async -> String? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func pandoraArtistURL(in html: String, for song: SongInfo) -> URL? {
        let artistSlug = pandoraSlugs(from: song.detailURL).artist ?? pandoraSlug(for: song.artist)
        let escapedName = NSRegularExpression.escapedPattern(for: song.artist)
        let escapedSlug = NSRegularExpression.escapedPattern(for: artistSlug)

        let patterns = [
            "\"name\"\\s*:\\s*\"\(escapedName)\"[\\s\\S]{0,3000}?\"shareableUrlPath\"\\s*:\\s*\"((?:\\\\/|/)artist(?:\\\\/|/)[^\"]+(?:\\\\/|/)AR[^\"]+)\"",
            "\"shareableUrlPath\"\\s*:\\s*\"((?:\\\\/|/)artist(?:\\\\/|/)\(escapedSlug)(?:\\\\/|/)AR[^\"]+)\""
        ]

        for pattern in patterns {
            guard let rawPath = firstCapture(in: html, pattern: pattern) else { continue }
            let path = rawPath.replacingOccurrences(of: "\\/", with: "/")
            if let url = URL(string: "https://www.pandora.com\(path)") {
                return url
            }
        }
        return nil
    }

    private func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[captureRange])
    }

    @ViewBuilder
    private var albumArt: some View {
        if let url = state.currentSong?.coverArtURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                placeholderArt
            }
        } else {
            placeholderArt
        }
    }

    private var placeholderArt: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.2))
            .overlay(
                Image(systemName: "music.note")
                    .font(.title)
                    .foregroundStyle(.secondary)
            )
    }
}
