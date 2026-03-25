import SwiftUI

@main
struct SyncVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var updaterService = UpdaterService()
    @StateObject private var tokenImporter = TokenImporter()
    @Environment(\.openWindow) private var openWindow

    init() {
        // Connect the token importer to the AppDelegate after init
        DispatchQueue.main.async { [tokenImporter] in
            AppDelegate.shared?.tokenImporter = tokenImporter
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState, updaterService: updaterService)
        } label: {
            MenuBarIcon(isSyncing: appState.isSyncing, isConnected: appState.isConnected, syncProgress: appState.syncProgress)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: tokenImporter.pendingData) { _, newValue in
            if newValue != nil {
                openWindow(id: "token-import")
            }
        }

        Settings {
            SettingsView(appState: appState, updaterService: updaterService)
        }

        // PIN entry window — shown when a .syncvault file is opened.
        Window("Connect with Token", id: "token-import") {
            PINEntryView(tokenImporter: tokenImporter, appState: appState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

// MARK: - App Delegate for file open events

class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    var tokenImporter: TokenImporter?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.pathExtension == "syncvault" else { continue }
            tokenImporter?.load(url: url)
            break
        }
    }
}

// MARK: - Token Importer (Observable state for file-open flow)

@MainActor
class TokenImporter: ObservableObject {
    @Published var pendingData: Data?
    @Published var pin: String = ""
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false

    func load(url: URL) {
        guard url.pathExtension == "syncvault",
              let data = try? Data(contentsOf: url) else {
            return
        }
        pendingData = data
        pin = ""
        errorMessage = nil
        // The app's .onChange(of: tokenImporter.pendingData) will open the window.
    }

    func connect(appState: AppState) async {
        guard let data = pendingData else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let connData = try TokenHandler.decrypt(data: data, pin: pin)
            try await appState.connect(
                url: connData.serverURL,
                username: connData.username,
                password: connData.password
            )
            // Success — reset state and close the window.
            pendingData = nil
            pin = ""
            errorMessage = nil
            closeWindow()
        } catch TokenError.invalidPIN {
            errorMessage = "Incorrect PIN. Please try again."
        } catch TokenError.invalidToken {
            errorMessage = "The token file appears to be corrupted."
            pendingData = nil
            closeWindow()
        } catch {
            errorMessage = "Connection failed: \(error.localizedDescription)"
        }
    }

    func cancel() {
        pendingData = nil
        pin = ""
        errorMessage = nil
        closeWindow()
    }

    private func closeWindow() {
        NSApp.windows
            .first { $0.title == "Connect with Token" }?
            .close()
    }
}

// MARK: - PIN Entry View

struct PINEntryView: View {
    @ObservedObject var tokenImporter: TokenImporter
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundColor(.blue)

            Text("Enter Connection PIN")
                .font(.headline)

            Text("Enter the 6-character PIN from your welcome email to connect automatically.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 6) {
                TextField("PIN (e.g. AB3X7K)", text: $tokenImporter.pin)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: tokenImporter.pin) { _, newValue in
                        // Force uppercase and cap at 6 characters.
                        tokenImporter.pin = String(newValue.uppercased().prefix(6))
                    }
                    .onSubmit {
                        submitIfReady()
                    }

                if let error = tokenImporter.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            HStack {
                Button("Cancel") {
                    tokenImporter.cancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(tokenImporter.isLoading ? "Connecting…" : "Connect") {
                    submitIfReady()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tokenImporter.pin.count != 6 || tokenImporter.isLoading)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    private func submitIfReady() {
        guard tokenImporter.pin.count == 6, !tokenImporter.isLoading else { return }
        Task { await tokenImporter.connect(appState: appState) }
    }
}
