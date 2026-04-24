import AppKit
import Carbon
import Combine
import PianobarCore

@MainActor
final class GlobalHotkeys {
    enum Action: String, CaseIterable {
        case playPause, next, love, ban

        var prefsKey: String { "hotkey.\(rawValue)" }

        /// Stable 1-indexed Carbon hotkey id.
        var hotKeyId: UInt32 {
            UInt32(Action.allCases.firstIndex(of: self)! + 1)
        }
    }

    private let ctrl: PianobarCtrl
    private let state: PlaybackState
    private var handlers: [Action: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private static var shared: GlobalHotkeys?  // for Carbon C callback

    init(state: PlaybackState, ctrl: PianobarCtrl) {
        self.state = state
        self.ctrl = ctrl
        GlobalHotkeys.shared = self
        installCarbonHandler()
        reloadAllBindings()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reloadAllBindings() }
        }
    }

    func reloadAllBindings() {
        for action in Action.allCases {
            unregister(action: action)
            if let (key, mods) = readBinding(action) {
                register(action: action, keyCode: key, modifiers: mods)
            }
        }
    }

    private func readBinding(_ action: Action) -> (UInt32, UInt32)? {
        let encoded = UserDefaults.standard.string(forKey: action.prefsKey)
        guard let encoded, !encoded.isEmpty else { return nil }
        let parts = encoded.split(separator: ",").compactMap { UInt32($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    private func register(action: Action, keyCode: UInt32, modifiers: UInt32) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(bitPattern: 0x50475549), // "PGUI"
                                     id: action.hotKeyId)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr, let ref = hotKeyRef {
            handlers[action] = ref
        }
    }

    private func unregister(action: Action) {
        if let ref = handlers[action] {
            UnregisterEventHotKey(ref)
            handlers.removeValue(forKey: action)
        }
    }

    private func installCarbonHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
                            { (_, event, _) -> OSStatus in
                                var hotKeyID = EventHotKeyID()
                                GetEventParameter(event, OSType(kEventParamDirectObject),
                                                  OSType(typeEventHotKeyID),
                                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                                Task { @MainActor in
                                    GlobalHotkeys.shared?.dispatch(id: hotKeyID.id)
                                }
                                return noErr
                            }, 1, &spec, nil, &handlerRef)
    }

    private func dispatch(id: UInt32) {
        for action in Action.allCases where action.hotKeyId == id {
            fire(action)
        }
    }

    private func fire(_ action: Action) {
        Task { [weak self] in
            guard let self else { return }
            switch action {
            case .playPause:
                try? await self.ctrl.togglePlay()
                self.state.setPlaying(!self.state.isPlaying)
            case .next: try? await self.ctrl.next()
            case .love: try? await self.ctrl.love()
            case .ban:  try? await self.ctrl.ban()
            }
        }
    }
}
