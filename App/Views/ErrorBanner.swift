import SwiftUI

struct ErrorBanner: View {
    let message: String
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).lineLimit(2)
            Spacer()
            if let retry = onRetry {
                Button("Retry", action: retry).buttonStyle(.borderless)
            }
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.15))
    }
}
