import Foundation

public enum EventParser {
    /// Parse a pianobar event. Returns nil if the event is unknown or the payload
    /// is unusable. Never throws.
    public static func parse(eventType: String, payload: String) -> PianobarEvent? {
        let kv = parseKeyValues(payload)

        let wRet = kv["wRet"].flatMap(Int.init) ?? 0
        let pRet = kv["pRet"].flatMap(Int.init) ?? 1

        // `userlogin` must be decided before the generic failure checks below.
        // Otherwise a sign-in that fails at the transport layer (no network,
        // TLS failure, Pandora 5xx) produced a `.networkError` whose banner
        // auto-clears after 30s, leaving the app looking idle and healthy while
        // actually being unauthenticated, and never routing back to login.
        if eventType == "userlogin" {
            let ok = wRet == 0 && pRet == 1
            let message = wRet != 0
                ? (kv["wRetStr"] ?? "Network error")
                : (kv["pRetStr"] ?? "")
            return .userLogin(success: ok, message: message)
        }

        // A command that failed entirely: surface the failure instead of the
        // nominal event.
        if wRet != 0 {
            return .networkError(message: kv["wRetStr"] ?? "Network error")
        }
        // Pandora-side failures (station limit reached, skip limit, etc.) were
        // previously dropped on the floor — only `wRet` was ever checked.
        if pRet != 1 {
            return .pandoraError(code: pRet, message: kv["pRetStr"] ?? "Pandora error")
        }

        switch eventType {
        case "songstart":
            return songStart(from: kv)
        case "songfinish":
            return .songFinish
        case "songlove":
            return .songLove
        case "songban":
            return .songBan
        case "songshelf":
            return .songShelf
        case "songbookmark":
            return .songBookmark
        case "artistbookmark":
            return .artistBookmark
        case "stationfetchplaylist":
            return .stationFetchPlaylist
        // pianobar dumps the full `station<N>=` list on station mutations just
        // as it does for `usergetstations`, so all of these carry a complete,
        // authoritative list. Replacing wholesale keeps the sidebar in step and
        // — since station commands address stations by array index — keeps
        // those indices aligned with pianobar's own ordering.
        case "usergetstations", "stationcreate", "stationdelete",
             "stationrename", "stationaddmusic", "stationaddgenre",
             "stationquickmixtoggle":
            let list = stations(from: kv)
            return list.isEmpty ? nil : .stationsChanged(list)
        default:
            return nil
        }
    }

    private static func parseKeyValues(_ payload: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in payload.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...])
            out[key] = value
        }
        return out
    }

    private static func songStart(from kv: [String: String]) -> PianobarEvent? {
        guard let title = kv["title"], let artist = kv["artist"] else { return nil }
        let song = SongInfo(
            title: title,
            artist: artist,
            album: kv["album"] ?? "",
            coverArtURL: kv["coverArt"].flatMap(httpsURL),
            durationSeconds: kv["songDuration"].flatMap(Int.init) ?? 0,
            rating: Rating(pianobarInt: kv["rating"].flatMap(Int.init) ?? 0),
            detailURL: firstURL(in: kv, keys: ["detailUrl", "songDetailUrl", "titleUrl"]),
            artistDetailURL: firstURL(in: kv, keys: ["artistDetailUrl", "artistUrl"]),
            albumDetailURL: firstURL(in: kv, keys: ["albumDetailUrl", "albumUrl"]),
            stationName: kv["stationName"] ?? ""
        )
        return .songStart(song)
    }

    private static func firstURL(in kv: [String: String], keys: [String]) -> URL? {
        for key in keys {
            if let value = kv[key], let url = URL(string: value) {
                return url
            }
        }
        return nil
    }

    /// Pianobar emits Pandora CDN URLs as `http://`, which modern macOS
    /// App Transport Security refuses to load. Pandora's CDN serves the
    /// same content over HTTPS, so rewrite the scheme before handing the
    /// URL to `AsyncImage` or `MPMediaItemArtwork`.
    private static func httpsURL(from string: String) -> URL? {
        guard !string.isEmpty else { return nil }
        let upgraded = string.hasPrefix("http://")
            ? "https://" + string.dropFirst("http://".count)
            : string
        return URL(string: upgraded)
    }

    private static func stations(from kv: [String: String]) -> [Station] {
        var list: [Station] = []
        var i = 0
        while let name = kv["station\(i)"] {
            let id = kv["stationId\(i)"] ?? String(i)
            list.append(Station(id: id, name: name, isQuickMix: false))
            i += 1
        }
        return list
    }
}
