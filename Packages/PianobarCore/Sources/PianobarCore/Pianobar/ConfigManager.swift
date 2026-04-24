import Foundation

public struct ConfigManager {
    public enum AudioQuality: String { case low, medium, high }

    private let configDir: URL

    public init(configDir: URL) {
        self.configDir = configDir
    }

    public func writeConfig(
        email: String,
        password: String,
        audioQuality: AudioQuality,
        eventBridgePath: String,
        fifoPath: String
    ) throws {
        try FileManager.default.createDirectory(
            at: configDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let body = """
        user = \(email)
        password = \(password)
        audio_quality = \(audioQuality.rawValue)
        autoselect = 1
        event_command = \(eventBridgePath)
        fifo = \(fifoPath)
        """

        let configFile = configDir.appendingPathComponent("config")
        try body.write(to: configFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: configFile.path)
    }
}
