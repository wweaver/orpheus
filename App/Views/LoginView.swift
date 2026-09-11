import SwiftUI

struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focused: Field?
    /// Populated when a previous sign-in attempt was rejected, so the user
    /// finds out why instead of landing in a blank window.
    var errorMessage: String?
    let onSubmit: (String, String) -> Void

    private enum Field { case email, password }

    var body: some View {
        VStack(spacing: 16) {
            Text("Sign in to Pandora").font(.title2)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(width: 260)
            }

            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .focused($focused, equals: .email)
                .onSubmit { focused = .password }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .focused($focused, equals: .password)
            Button("Sign In") { onSubmit(email, password) }
                .keyboardShortcut(.defaultAction)
                .disabled(email.isEmpty || password.isEmpty)
        }
        .padding(40)
        .onAppear { focused = .email }
    }
}
