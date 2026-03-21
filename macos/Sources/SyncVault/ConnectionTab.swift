import SwiftUI

struct ConnectionTab: View {
    @ObservedObject var appState: AppState
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isTesting = false
    @State private var testResult: String?

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server URL", text: $serverURL, prompt: Text("https://sync.example.com"))
                TextField("Username", text: $username)
                SecureField("Password", text: $password)
            }

            Section {
                HStack {
                    Button(appState.isConnected ? "Disconnect" : "Connect") {
                        if appState.isConnected {
                            appState.disconnect()
                        } else {
                            Task {
                                do {
                                    try await appState.connect(url: serverURL, username: username, password: password)
                                    testResult = "Connected successfully!"
                                } catch {
                                    testResult = "Error: \(error.localizedDescription)"
                                }
                            }
                        }
                    }

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(appState.isConnected ? .green : .red)
                    }
                }
            }

            if appState.isConnected {
                Section("Status") {
                    LabeledContent("Server", value: appState.serverURL)
                    LabeledContent("User", value: appState.username)
                    LabeledContent("Status", value: "Connected")
                }
            }
        }
        .padding()
        .onAppear {
            serverURL = appState.serverURL
            username = appState.username
        }
    }
}
