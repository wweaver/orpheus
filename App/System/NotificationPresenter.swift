import Foundation
import UserNotifications
import Combine
import PianobarCore

@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    private let state: PlaybackState
    private let ctrl: PianobarCtrl
    private var subs = Set<AnyCancellable>()
    private var lastSongTitleFired: String?

    init(state: PlaybackState, ctrl: PianobarCtrl) {
        self.state = state
        self.ctrl = ctrl
        super.init()
        configureCategories()
        requestAuthorization()
        observeSongChanges()
        UNUserNotificationCenter.current().delegate = self
    }

    private func configureCategories() {
        let love = UNNotificationAction(identifier: "love", title: "👍", options: [])
        let ban  = UNNotificationAction(identifier: "ban",  title: "👎", options: [])
        let skip = UNNotificationAction(identifier: "skip", title: "⏭", options: [])
        let category = UNNotificationCategory(
            identifier: "song.change",
            actions: [love, ban, skip],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func observeSongChanges() {
        state.$currentSong
            .sink { [weak self] song in
                guard let self, let song,
                      song.title != self.lastSongTitleFired else { return }
                self.lastSongTitleFired = song.title
                self.fire(for: song)
            }
            .store(in: &subs)
    }

    private func fire(for song: SongInfo) {
        guard UserDefaults.standard.bool(forKey: Prefs.Keys.showNotifications) else { return }
        let content = UNMutableNotificationContent()
        content.title = song.title
        content.body  = "\(song.artist) — \(song.album)"
        content.categoryIdentifier = "song.change"
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        Task { @MainActor [weak self] in
            guard let self else { completionHandler(); return }
            switch actionID {
            case "love": try? await self.ctrl.love()
            case "ban":  try? await self.ctrl.ban()
            case "skip": try? await self.ctrl.next()
            default: break
            }
            completionHandler()
        }
    }
}
