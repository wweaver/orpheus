import SwiftUI
import AppKit
import Carbon

/// Click-to-record control for a single global hotkey.
///
/// Replaces the old "write `<keyCode>,<modifierMask>` with `defaults write`"
/// instructions in Preferences. The Carbon registration plumbing already
/// existed in `GlobalHotkeys`; this just captures a key combination and writes
/// it to the same UserDefaults key in the same `keyCode,modifiers` format,
/// which `GlobalHotkeys` picks up via its defaults observer.
struct HotkeyRecorder: View {
    let title: String
    let prefsKey: String

    @State private var isRecording = false
    @AppStorage private var encoded: String

    init(title: String, prefsKey: String) {
        self.title = title
        self.prefsKey = prefsKey
        _encoded = AppStorage(wrappedValue: "", prefsKey)
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button {
                isRecording.toggle()
            } label: {
                Text(isRecording ? "Press keys…" : (displayString ?? "Record Shortcut"))
                    .frame(minWidth: 130)
                    .monospacedDigit()
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("\(title) shortcut: \(displayString ?? "none")")

            Button {
                encoded = ""
                isRecording = false
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Clear shortcut")
            .accessibilityLabel("Clear \(title) shortcut")
            .disabled(encoded.isEmpty)
        }
        .background(
            KeyCaptureView(isRecording: $isRecording) { keyCode, modifiers in
                // Require at least one modifier, otherwise a bare key would be
                // swallowed system-wide.
                guard modifiers != 0 else { return }
                encoded = "\(keyCode),\(modifiers)"
                isRecording = false
            }
        )
    }

    private var displayString: String? {
        let parts = encoded.split(separator: ",").compactMap { UInt32($0) }
        guard parts.count == 2 else { return nil }
        return HotkeyFormatter.describe(keyCode: parts[0], carbonModifiers: parts[1])
    }
}

/// Hosts an NSView that becomes first responder while recording and reports the
/// next key-down as a Carbon keycode + modifier mask.
private struct KeyCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = { isRecording = false }
        if isRecording {
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
        } else if nsView.window?.firstResponder === nsView {
            nsView.window?.makeFirstResponder(nil)
        }
    }

    final class CaptureView: NSView {
        var onCapture: ((UInt32, UInt32) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == UInt16(kVK_Escape) {
                onCancel?()
                return
            }
            onCapture?(UInt32(event.keyCode),
                       HotkeyFormatter.carbonModifiers(from: event.modifierFlags))
        }

        /// Swallow the key equivalent too, so ⌘-combinations reach keyDown
        /// instead of triggering a menu item while recording.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }
    }
}

enum HotkeyFormatter {
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    static func describe(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var out = ""
        if carbonModifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { out += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { out += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { out += "⌘" }
        return out + keyName(keyCode)
    }

    private static func keyName(_ keyCode: UInt32) -> String {
        if let special = specialKeys[Int(keyCode)] { return special }
        return characterForKeyCode(keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_F1: "F1", kVK_F2: "F2",
        kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Map a keycode to its character using the *current* keyboard layout, so
    /// the label matches what's printed on the user's keys.
    private static func characterForKeyCode(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data

        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress
            else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
