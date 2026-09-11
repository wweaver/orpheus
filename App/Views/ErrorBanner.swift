import SwiftUI

struct ErrorBanner: View {
    let message: String
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message).lineLimit(2)
            Spacer()
            if let retry = onRetry {
                Button("Retry", action: retry).buttonStyle(.borderless)
            }
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss message")
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        // A semantic material rather than a hardcoded yellow wash, so the
        // banner adapts to dark mode and increased-contrast settings.
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error: \(message)")
    }
}
