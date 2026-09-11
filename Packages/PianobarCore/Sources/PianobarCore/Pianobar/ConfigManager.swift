import Foundation

public struct ConfigManager {
    public enum AudioQuality: String { case low, medium, high }

    public enum Error: Swift.Error, Equatable {
        /// A credential contained a newline. pianobar's config is a line-based
        /// `key = value` format with no escaping, so a newline would corrupt
        /// the file (and could inject arbitrary config keys).
        case invalidCredentials
        /// The config file couldn't be created or written.
        case writeFailed(String)
    }

    private let configDir: URL

    public init(configDir: URL) {
        self.configDir = configDir
    }

    public func writeConfig(
        email: String,
        password: String,
        audioQuality: AudioQuality,
        eventBridgePath: String,
        fifoPath: String,
        autostartStationId: String? = nil
    ) throws {
        // pianobar's config is line-based with no escaping; a newline in a
        // credential would split the value across lines and corrupt the file.
        guard !email.contains(where: \.isNewline),
              !password.contains(where: \.isNewline)
        else { throw Error.invalidCredentials }

        try FileManager.default.createDirectory(
            at: configDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // `createDirectory` only applies attributes when it actually creates the
        // directory, so an existing dir left over from an earlier version keeps
        // whatever mode it had (typically 0755). Tighten it unconditionally —
        // the config inside holds a cleartext password.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: configDir.path)

        var lines = [
            "user = \(email)",
            "password = \(password)",
            "audio_quality = \(audioQuality.rawValue)",
            "autoselect = 1",
            "event_command = \(eventBridgePath)",
            "fifo = \(fifoPath)",
        ]
        if let id = autostartStationId, !id.isEmpty {
            lines.append("autostart_station = \(id)")
        }
        let body = lines.joined(separator: "\n")

        let configFile = configDir.appendingPathComponent("config")
        // Write through a file created 0600 up front rather than
        // `write(atomically:)`, which lays down a temp file at the default mode
        // (0644 after a typical umask) and renames it into place — leaving a
        // window where the cleartext Pandora password is world-readable.
        try writePrivately(body, to: configFile)
    }

    /// Create (or truncate) `url` with mode 0600 and write `body` into it, so
    /// the contents are never readable by other users, even transiently.
    private func writePrivately(_ body: String, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw Error.writeFailed(String(cString: strerror(errno))) }
        defer { close(fd) }
        // Enforce the mode even if the file already existed with a looser one,
        // since O_CREAT's mode argument is ignored for an existing file.
        guard fchmod(fd, 0o600) == 0 else {
            throw Error.writeFailed(String(cString: strerror(errno)))
        }
        let bytes = Array(body.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buf -> Int in
                Darwin.write(fd, buf.baseAddress!.advanced(by: offset), buf.count - offset)
            }
            guard written > 0 else {
                throw Error.writeFailed(String(cString: strerror(errno)))
            }
            offset += written
        }
    }
}
