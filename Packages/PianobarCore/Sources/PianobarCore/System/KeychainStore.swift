import Foundation
import Security
import os

public struct KeychainStore {
    public enum Error: Swift.Error, LocalizedError {
        case status(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .status(let code):
                let message = SecCopyErrorMessageString(code, nil) as String?
                return message ?? "Keychain error \(code)"
            }
        }
    }

    private static let log = Logger(subsystem: "org.pianobar-gui.PianobarGUI", category: "keychain")

    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func save(email: String, password: String) throws {
        delete() // replace any existing entry

        let data = Data("\(email)\n\(password)".utf8)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
            kSecValueData as String:   data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.status(status) }
    }

    /// Outcome of a credential lookup.
    ///
    /// "No credentials" and "couldn't read the credentials" are different
    /// situations and need different handling: the first means show the login
    /// screen, the second means something is wrong and saying so beats
    /// pretending the user never signed in. `load()` collapsed both to `nil`,
    /// which made a keychain that denied access look exactly like a first run.
    public enum LoadOutcome {
        case found(email: String, password: String)
        case notFound
        case failed(OSStatus)
    }

    public func loadOutcome() -> LoadOutcome {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return .notFound
        default:
            Self.log.error("keychain read failed: OSStatus \(status, privacy: .public)")
            return .failed(status)
        }
        guard let data = out as? Data,
              let decoded = String(data: data, encoding: .utf8)
        else { return .failed(errSecDecode) }
        let parts = decoded.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return .failed(errSecDecode) }
        return .found(email: parts[0], password: parts[1])
    }

    public func load() -> (email: String, password: String)? {
        guard case .found(let email, let password) = loadOutcome() else { return nil }
        return (email, password)
    }

    public func delete() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
