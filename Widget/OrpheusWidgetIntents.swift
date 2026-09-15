import AppIntents
import Foundation

/// A widget button press, forwarded to the running Orpheus.
///
/// `perform()` runs in the *widget extension's* process, which is sandboxed and
/// has no access to pianobar's control FIFO — pianobar is a child of the main
/// app. So this does the only thing it can: post a distributed notification and
/// let WidgetBridge, over in the app, translate it into a PianobarCtrl call.
///
/// Fire-and-forget by necessity. There is no reply channel, and nothing is
/// listening when Orpheus isn't running — which is why the snapshot carries
/// `appRunning` and the views hide the transport when it's false.
struct OrpheusCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Orpheus Playback Command"
    /// The app must stay in the background. Launching Orpheus to the front on
    /// every play/pause would defeat the point of having the widget.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Command")
    var command: String

    init() {}
    init(_ command: OrpheusCommand) { self.command = command.rawValue }

    func perform() async throws -> some IntentResult {
        DistributedNotificationCenter.default().postNotificationName(
            OrpheusShared.commandNotification,
            object: command,
            userInfo: nil,
            deliverImmediately: true
        )
        return .result()
    }
}
