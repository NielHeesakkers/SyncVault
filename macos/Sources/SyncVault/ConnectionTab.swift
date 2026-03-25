import SwiftUI

struct ConnectionTab: View {
    @ObservedObject var appState: AppState
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var hasStoredPassword = false

    enum TestResult {
        case success(String)
        case error(String)

        var message: String {
            switch self {
            case .success(let msg): return msg
            case .error(let msg): return msg
            }
        }
        var color: Color {
            switch self {
            case .success: return .green
            case .error: return .red
            }
        }
    }

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
                    SecureField(hasStoredPassword && password.isEmpty ? "••••••••" : "Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .disabled(appState.isConnected)
                }
            }

            // Buttons
            HStack(spacing: 12) {
                if appState.isConnected {
                    Button("Disconnect") {
                        appState.disconnect()
                        testResult = nil
                        password = ""
                        hasStoredPassword = false
                    }
                } else {
                    Button("Connect") {
                        isConnecting = true
                        testResult = nil
                        Task {
                            do {
                                try await appState.connect(url: serverURL, username: username, password: password)
                                testResult = .success("Connected")
                                hasStoredPassword = true
                            } catch {
                                testResult = .error(error.localizedDescription)
                            }
                            isConnecting = false
                        }
                    }
                    .disabled(serverURL.isEmpty || username.isEmpty || (password.isEmpty && !hasStoredPassword) || isConnecting)
                }

                Button("Test Server") {
                    testServer()
                }
                .disabled(serverURL.isEmpty || isTesting)

                if isConnecting || isTesting {
                    ProgressView()
                        .scaleEffect(0.6)
                }

                if let result = testResult {
                    Text(result.message)
                        .font(.system(size: 11))
                        .foregroundColor(result.color)
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
            hasStoredPassword = KeychainHelper.load(key: "server_password") != nil
        }
    }

    private func testServer() {
        isTesting = true
        testResult = nil
        let urlStr = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(urlStr)/api/health") else {
            testResult = .error("Invalid URL")
            isTesting = false
            return
        }

        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    testResult = .error("Invalid response")
                    isTesting = false
                    return
                }
                if http.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let version = json["version"] as? String {
                        testResult = .success("Server OK — v\(version)")
                    } else {
                        testResult = .success("Server reachable")
                    }
                } else {
                    testResult = .error("HTTP \(http.statusCode)")
                }
            } catch {
                testResult = .error("Cannot reach server")
            }
            isTesting = false
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
