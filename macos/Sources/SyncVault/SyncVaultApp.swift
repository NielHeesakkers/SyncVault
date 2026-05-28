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
                .onReceive(NotificationCenter.default.publisher(for: .openUpdateWindow)) { _ in
                    openWindow(id: "update-window")
                }
                .onReceive(NotificationCenter.default.publisher(for: .openOnboardingWindow)) { _ in
                    openWindow(id: "onboarding")
                }
                .onReceive(NotificationCenter.default.publisher(for: .openTrashWindow)) { _ in
                    openWindow(id: "trash")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: .openRestoreFilesWindow)) { _ in
                    openWindow(id: "restore-files")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onAppear {
                    // First-launch gate: show onboarding once if the user has
                    // never finished the wizard.
                    if OnboardingController.needsOnboarding {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            NotificationCenter.default.post(name: .openOnboardingWindow, object: nil)
                        }
                    }
                }
        } label: {
            MenuBarIcon(state: appState.menuBarState(availableVersion: updaterService.availableVersion))
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

        // Dedicated update window — drives download/install via UpdateWindowController.
        Window("SyncVault Update", id: "update-window") {
            if let c = updaterService.updateWindowController {
                UpdateWindowView(controller: c)
                    .onDisappear {
                        // Release controller so a fresh one is built next time, but
                        // keep it around if a download already finished (so reopening
                        // still shows the "Quit & Install" state).
                        if case .ready = c.state { } else {
                            updaterService.updateWindowController = nil
                        }
                    }
            } else {
                EmptyView().frame(width: 1, height: 1)
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        // First-launch onboarding wizard — 4-step modal opened on launch
        // when OnboardingController.needsOnboarding is true.
        Window("Welcome to SyncVault", id: "onboarding") {
            OnboardingView { dismissOnboardingWindow() }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        // Trash window — opened from the menu bar's "Open Trash…" row. Standard
        // window chrome (resizable, traffic lights) so power users can keep it
        // open while they triage many deletions.
        Window("Trash", id: "trash") {
            TrashView(appState: appState)
        }
        .windowResizability(.contentMinSize)

        // Restore Files window — Synology-style point-in-time browser opened
        // from the menu bar's "Restore Files…" row. Lets the user pick a
        // restore point per folder and roll the contents back to that snapshot.
        Window("Restore Files", id: "restore-files") {
            RestoreFilesView(appState: appState)
        }
        .windowResizability(.contentMinSize)
    }

    private func dismissOnboardingWindow() {
        NSApp.windows.first(where: { $0.identifier?.rawValue == "onboarding" })?.close()
    }
}

extension Notification.Name {
    static let openOnboardingWindow = Notification.Name("openOnboardingWindow")
    static let openTrashWindow = Notification.Name("openTrashWindow")
    static let openRestoreFilesWindow = Notification.Name("openRestoreFilesWindow")
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
