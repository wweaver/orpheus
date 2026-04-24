import Foundation

public enum Rating: Equatable, Sendable {
    case unrated
    case loved
    case banned

    public init(pianobarInt: Int) {
        switch pianobarInt {
        case 1:  self = .loved
        case -1: self = .banned
        default: self = .unrated
        }
    }
}
