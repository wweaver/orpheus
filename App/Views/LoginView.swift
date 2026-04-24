import SwiftUI

struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    let onSubmit: (String, String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Sign in to Pandora").font(.title2)
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            Button("Sign In") { onSubmit(email, password) }
                .keyboardShortcut(.defaultAction)
                .disabled(email.isEmpty || password.isEmpty)
        }
        .padding(40)
    }
}
