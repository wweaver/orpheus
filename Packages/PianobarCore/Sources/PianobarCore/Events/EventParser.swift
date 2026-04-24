import Foundation

public enum EventParser {
    /// Parse a pianobar event. Returns nil if the event is unknown or the payload
    /// is unusable. Never throws.
    public static func parse(eventType: String, payload: String) -> PianobarEvent? {
        let kv = parseKeyValues(payload)

        // Check Pandora/network result codes first — if a command failed entirely
        // with a network error, surface it instead of the nominal event.
        if let wRet = kv["wRet"].flatMap(Int.init), wRet != 0 {
            return .networkError(message: kv["wRetStr"] ?? "Network error")
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
        case "usergetstations":
            return .stationsChanged(stations(from: kv))
        case "userlogin":
            let ok = (kv["pRet"].flatMap(Int.init) ?? 0) == 1
            return .userLogin(success: ok, message: kv["pRetStr"] ?? "")
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
            coverArtURL: kv["coverArt"].flatMap(URL.init),
            durationSeconds: kv["songDuration"].flatMap(Int.init) ?? 0,
            rating: Rating(pianobarInt: kv["rating"].flatMap(Int.init) ?? 0),
            detailURL: kv["detailUrl"].flatMap(URL.init),
            stationName: kv["stationName"] ?? ""
        )
        return .songStart(song)
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
