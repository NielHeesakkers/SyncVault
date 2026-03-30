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
        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error: return "xmark.circle.fill"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: - Server fields card
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Server")
                        .padding(.bottom, 10)

                    VStack(spacing: 0) {
                        fieldRow(label: "URL", systemImage: "globe") {
                            TextField("https://sync.example.com", text: $serverURL)
                                .textFieldStyle(.plain)
                                .disabled(appState.isConnected)
                                .foregroundColor(appState.isConnected ? .secondary : .primary)
                        }
                        insetDivider
                        fieldRow(label: "Username", systemImage: "person") {
                            TextField("Username", text: $username)
                                .textFieldStyle(.plain)
                                .disabled(appState.isConnected)
                                .foregroundColor(appState.isConnected ? .secondary : .primary)
                        }
                        insetDivider
                        fieldRow(label: "Password", systemImage: "lock") {
                            SecureField(hasStoredPassword && password.isEmpty ? "••••••••" : "Password", text: $password)
                                .textFieldStyle(.plain)
                                .disabled(appState.isConnected)
                                .foregroundColor(appState.isConnected ? .secondary : .primary)
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                            )
                    )
                }

                // MARK: - Buttons
                HStack(spacing: 10) {
                    if appState.isConnected {
                        Button("Disconnect") {
                            appState.disconnect()
                            testResult = nil
                            password = ""
                            hasStoredPassword = false
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button {
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
                        } label: {
                            HStack(spacing: 6) {
                                if isConnecting {
                                    ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                                }
                                Text(isConnecting ? "Connecting..." : "Connect")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(serverURL.isEmpty || username.isEmpty || (password.isEmpty && !hasStoredPassword) || isConnecting)
                    }

                    Button {
                        testServer()
                    } label: {
                        HStack(spacing: 6) {
                            if isTesting {
                                ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "network")
                                    .font(.system(size: 11))
                            }
                            Text(isTesting ? "Testing..." : "Test Server")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(serverURL.isEmpty || isTesting)

                    Spacer()
                }

                // Test result feedback
                if let result = testResult {
                    HStack(spacing: 6) {
                        Image(systemName: result.icon)
                            .foregroundColor(result.color)
                        Text(result.message)
                            .font(.system(size: 12))
                            .foregroundColor(result.color)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(result.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(result.color.opacity(0.2), lineWidth: 0.5))
                }

                // MARK: - Status section (when connected)
                if appState.isConnected {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Status")

                        HStack(spacing: 14) {
                            PulsingDot(color: .green)
                                .scaleEffect(1.5)
                                .frame(width: 16, height: 16)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.icloud.fill")
                                        .foregroundColor(.green)
                                        .font(.system(size: 13))
                                    Text("Connected as \(appState.username)")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                HStack(spacing: 4) {
                                    Image(systemName: "globe")
                                        .font(.system(size: 10))
                                        .foregroundColor(.blue)
                                    Text(appState.serverURL)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.green.opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.green.opacity(0.2), lineWidth: 0.5)
                                )
                        )
                    }
                }

                Spacer()
            }
            .padding(20)
        }
        .onAppear {
            serverURL = appState.serverURL
            username = appState.username
            hasStoredPassword = KeychainHelper.load(key: "server_password") != nil
            // Auto-test server connection if not connected and URL is filled
            if !appState.isConnected && !serverURL.isEmpty && testResult == nil {
                testServer()
            }
        }
    }

    // MARK: - Row builder

    private func fieldRow<Content: View>(label: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 68, alignment: .leading)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var insetDivider: some View {
        Divider()
            .padding(.leading, 14 + 16 + 10) // indent past icon
    }

    // MARK: - Test logic (unchanged)

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
