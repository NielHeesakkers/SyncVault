import SwiftUI

struct ConnectStep: View {
    @ObservedObject var controller: OnboardingController
    @State private var testStatus: String = ""
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: SVSpacing.xl) {
            Text("Connect to your server").font(.system(size: 18, weight: .semibold))
            Text("De URL waar je SyncVault-server draait, plus je login.")
                .font(SVFont.body(12.5)).foregroundStyle(SVColor.textSecondary)

            field("Server URL", text: $controller.serverURL)
            field("Username", text: $controller.username)
            field("Password", text: $controller.password, secure: true)

            if !testStatus.isEmpty {
                HStack(spacing: 8) {
                    Circle().fill(controller.connectionTested ? SVColor.accentGreen : SVColor.accentRed)
                        .frame(width: 8, height: 8)
                        .shadow(color: (controller.connectionTested ? SVColor.accentGreen : SVColor.accentRed).opacity(0.6), radius: 4)
                    Text(testStatus).font(SVFont.body(12)).foregroundStyle(controller.connectionTested ? SVColor.accentGreen : SVColor.accentRed)
                }
            }
        }
        .frame(maxWidth: 380)
        .padding(SVSpacing.xxxl)
        .frame(maxWidth: .infinity, alignment: .top)
        .onChange(of: controller.serverURL) { _, _ in scheduleTest() }
        .onChange(of: controller.username)  { _, _ in scheduleTest() }
        .onChange(of: controller.password)  { _, _ in scheduleTest() }
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(SVFont.body(11)).foregroundStyle(SVColor.textSecondary)
            Group {
                if secure { SecureField("", text: text) } else { TextField("", text: text) }
            }
            .textFieldStyle(.plain)
            .font(SVFont.mono(12.5))
            .padding(.horizontal, SVSpacing.l).padding(.vertical, 9)
            .background(SVColor.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: SVRadius.card - 1))
        }
    }

    private func scheduleTest() {
        controller.connectionTested = false
        testStatus = ""
        testTask?.cancel()
        guard !controller.serverURL.isEmpty, !controller.username.isEmpty, !controller.password.isEmpty else { return }
        testTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            await runTest()
        }
    }

    private func runTest() async {
        testing = true
        defer { testing = false }
        // Cheap probe: hit /api/health on the server URL.
        guard let baseURL = URL(string: controller.serverURL) else {
            testStatus = "Invalid URL"; return
        }
        let health = baseURL.appendingPathComponent("api/health")
        do {
            let start = Date()
            var req = URLRequest(url: health)
            req.timeoutInterval = 5
            let (data, resp) = try await URLSession.shared.data(for: req)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                testStatus = "Server returned \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let serverVersion = (json?["version"] as? String) ?? "?"
            controller.connectionTested = true
            testStatus = "Connected · server v\(serverVersion) · \(elapsed) ms latency"
        } catch {
            testStatus = "Connection failed: \(error.localizedDescription)"
        }
    }
}
