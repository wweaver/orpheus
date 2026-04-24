import AppKit
import Combine
import PianobarCore

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private weak var bootstrap: AppBootstrap?
    private var subs = Set<AnyCancellable>()

    init(bootstrap: AppBootstrap) {
        self.bootstrap = bootstrap
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "♪"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(primaryClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        observe()
    }

    private func observe() {
        guard let bootstrap else { return }
        bootstrap.$playbackState
            .compactMap { $0 }
            .sink { [weak self] state in
                state.$currentSong.sink { [weak self] _ in self?.refreshTitle() }
                    .store(in: &self!.subs)
            }
            .store(in: &subs)
    }

    private func refreshTitle() {
        guard let song = bootstrap?.playbackState?.currentSong else {
            statusItem.button?.title = "♪"
            return
        }
        let showTitle  = UserDefaults.standard.bool(forKey: Prefs.Keys.menuBarShowTitle)
        let showArtist = UserDefaults.standard.bool(forKey: Prefs.Keys.menuBarShowArtist)
        let maxWidth   = max(10, UserDefaults.standard.integer(forKey: Prefs.Keys.menuBarMaxWidth))
        var parts: [String] = []
        if showArtist { parts.append(song.artist) }
        if showTitle  { parts.append(song.title) }
        let raw = parts.joined(separator: " — ")
        let truncated = raw.count > maxWidth
            ? String(raw.prefix(maxWidth - 1)) + "…"
            : raw
        statusItem.button?.title = "♪ " + truncated
    }

    @objc private func primaryClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            presentMenu()
        } else {
            activateMainWindow()
        }
    }

    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title.contains("PianobarGUI") || $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func presentMenu() {
        let menu = buildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        guard let bootstrap, let state = bootstrap.playbackState, let ctrl = bootstrap.ctrl else {
            let item = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(NSMenuItem(title: "Quit PianobarGUI",
                                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            return menu
        }

        let playTitle = state.isPlaying ? "Pause" : "Play"
        menu.addItem(commandItem(title: playTitle, key: "p") {
            Task { try? await ctrl.togglePlay(); state.setPlaying(!state.isPlaying) }
        })
        menu.addItem(commandItem(title: "Next", key: "") {
            Task { try? await ctrl.next() }
        })
        menu.addItem(commandItem(title: "Thumbs Up", key: "") {
            Task { try? await ctrl.love() }
        })
        menu.addItem(commandItem(title: "Thumbs Down", key: "") {
            Task { try? await ctrl.ban() }
        })
        menu.addItem(.separator())

        let stationsItem = NSMenuItem(title: "Stations", action: nil, keyEquivalent: "")
        let stationsMenu = NSMenu()
        for (idx, station) in state.stations.enumerated() {
            let item = commandItem(title: station.name, key: "") {
                Task { try? await ctrl.switchStation(index: idx) }
            }
            if station.id == state.currentStation?.id { item.state = .on }
            stationsMenu.addItem(item)
        }
        stationsItem.submenu = stationsMenu
        menu.addItem(stationsItem)

        menu.addItem(.separator())
        let showItem = NSMenuItem(title: "Show PianobarGUI",
                                  action: #selector(activateMainWindowSelector),
                                  keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(NSMenuItem(title: "Quit PianobarGUI",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func commandItem(title: String, key: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runClosure(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = ClosureBox(action)
        return item
    }

    @objc private func runClosure(_ sender: NSMenuItem) {
        (sender.representedObject as? ClosureBox)?.run()
    }

    @objc private func activateMainWindowSelector() { activateMainWindow() }
}

private final class ClosureBox {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    func run() { action() }
}
