import SwiftUI

struct LoginView: View {
  @Environment(AppModel.self) private var model
  @AppStorage("lastServer") private var server = ""
  @AppStorage("lastEmail") private var email = ""
  @State private var password = ""
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath.icloud")
              .font(.system(size: 44)).foregroundStyle(.tint)
            Text("Photo Mirror Sync").font(.largeTitle.bold())
            Text(
              "Keeps your Immich library identical to your iCloud Photos — new photos, edits, deletions and albums."
            )
            .font(.subheadline).foregroundStyle(.secondary)
          }
          .padding(.vertical, 8)
          .listRowBackground(Color.clear)
        }
        Section("Server") {
          TextField("https://immich.example.com", text: $server)
            .textContentType(.URL).keyboardType(.URL)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        Section("Account") {
          TextField("Email", text: $email)
            .textContentType(.username).keyboardType(.emailAddress)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          SecureField("Password", text: $password).textContentType(.password)
        }
        if let error {
          Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        }
        Section {
          Button {
            Task { await signIn() }
          } label: {
            HStack {
              Spacer()
              if busy { ProgressView() } else { Text("Sign In").bold() }
              Spacer()
            }
          }
          .disabled(busy || server.isEmpty || email.isEmpty || password.isEmpty)
        }
      }
    }
  }

  private func signIn() async {
    busy = true
    error = nil
    defer { busy = false }
    do {
      try await model.signIn(server: server, email: email, password: password)
      password = ""
    } catch {
      self.error = error.localizedDescription
    }
  }
}
