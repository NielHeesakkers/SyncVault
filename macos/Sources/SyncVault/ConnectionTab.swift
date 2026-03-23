import SwiftUI

struct ConnectionTab: View {
    @ObservedObject var appState: AppState
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var testResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Server fields
            VStack(alignment: .leading, spacing: 12) {
                Text("Server")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                LabeledField("URL") {
                    TextField("https://sync.example.com", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(appState.isConnected)
                }

                LabeledField("Username") {
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .disabled(appState.isConnected)
                }

                LabeledField("Password") {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .disabled(appState.isConnected)
                }
            }

            // Connect / Disconnect
            HStack(spacing: 12) {
                if appState.isConnected {
                    Button("Disconnect") {
                        appState.disconnect()
                        testResult = nil
                    }
                } else {
                    Button("Connect") {
                        isConnecting = true
                        testResult = nil
                        Task {
                            do {
                                try await appState.connect(url: serverURL, username: username, password: password)
                                testResult = "Connected"
                            } catch {
                                testResult = error.localizedDescription
                            }
                            isConnecting = false
                        }
                    }
                    .disabled(serverURL.isEmpty || username.isEmpty || password.isEmpty || isConnecting)
                }

                if isConnecting {
                    ProgressView()
                        .scaleEffect(0.6)
                }

                if let result = testResult {
                    Text(result)
                        .font(.system(size: 11))
                        .foregroundColor(appState.isConnected ? .green : .red)
                        .lineLimit(1)
                }
            }

            // Status
            if appState.isConnected {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Status")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)

                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("Connected as \(appState.username)")
                            .font(.system(size: 12))
                    }

                    Text(appState.serverURL)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(20)
        .onAppear {
            serverURL = appState.serverURL
            username = appState.username
        }
    }
}

// MARK: - Labeled Field Helper

struct LabeledField<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 70, alignment: .trailing)
            content
        }
    }
}
