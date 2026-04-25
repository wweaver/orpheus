import Foundation

public struct Station: Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var isQuickMix: Bool

    public init(id: String, name: String, isQuickMix: Bool) {
        self.id = id
        self.name = name
        self.isQuickMix = isQuickMix
    }
}
