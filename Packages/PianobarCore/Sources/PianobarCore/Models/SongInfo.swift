import Foundation

public struct SongInfo: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var coverArtURL: URL?
    public var durationSeconds: Int
    public var rating: Rating
    public var detailURL: URL?
    public var artistDetailURL: URL?
    public var albumDetailURL: URL?
    public var stationName: String

    public init(
        title: String,
        artist: String,
        album: String,
        coverArtURL: URL?,
        durationSeconds: Int,
        rating: Rating,
        detailURL: URL?,
        artistDetailURL: URL? = nil,
        albumDetailURL: URL? = nil,
        stationName: String
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.coverArtURL = coverArtURL
        self.durationSeconds = durationSeconds
        self.rating = rating
        self.detailURL = detailURL
        self.artistDetailURL = artistDetailURL
        self.albumDetailURL = albumDetailURL
        self.stationName = stationName
    }
}
