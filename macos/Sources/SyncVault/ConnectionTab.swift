import SwiftUI

struct ConnectionTab: View {
    @ObservedObject var appState: AppState

    // Inline sign-in form state. Shown whenever the app is offline. URL and
    // username are editable too so you can switch servers or fix a typo without
    // resetting config. Defaults hydrate from whatever AppState has on disk.
    @State private var signInURL: String = ""
    @State private var signInUsername: String = ""
    @State private var signInPassword: String = ""
    @State private var signInError: String? = nil
    @State private var signingIn: Bool = false
    @State private var hydratedFields = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Page title + inline meta — replaces the 3 fat health cards.
                // Same data (status / latency / uptime) in one line on the right.
                HStack(alignment: .firstTextBaseline) {
                    Text("Connection")
                        .font(SVFont.bodyBold(17))
                    Spacer()
                    headerMeta
                }
                .padding(.bottom, SVSpacing.l)

                // SERVER — online: readonly URL + "Signed in as" + Sign Out.
                // Offline: editable URL + Username + Password + Sign In.
                SVSectionLabel(text: "Server")
                if appState.isConnected {
                    serverCard.padding(.bottom, SVSpacing.l)
                } else {
                    signInCard.padding(.bottom, SVSpacing.l)
                }

                // VERSIONS
                SVSectionLabel(text: "Versions")
                versionsCard.padding(.bottom, SVSpacing.l)

                // THIS DEVICE
                SVSectionLabel(text: "This device")
                deviceCard

                // ACTIONS
                HStack(spacing: SVSpacing.m) {
                    Button("Reconnect") { Task { await appState.reconnect() } }
                        .buttonStyle(.borderedProminent)
                        .tint(SVColor.accentBlue)
                    Button("Test Server") { Task { await appState.testServer() } }
                        .buttonStyle(.bordered)
                }
                .padding(.top, SVSpacing.xl)
            }
            .padding(SVSpacing.xxxl)
        }
        .background(SVColor.windowBg)
    }

    /// Inline status / latency / uptime row that replaces the old healthCards.
    /// Lives in the page-title row, right-aligned, mono numbers, middle-dot separators.
    private var headerMeta: some View {
        HStack(spacing: SVSpacing.m) {
            // Status dot + label
            HStack(spacing: 6) {
                Circle()
                    .fill(appState.isConnected ? SVColor.accentGreen : SVColor.accentRed)
                    .frame(width: 7, height: 7)
                Text(appState.isConnected ? "Online" : "Offline")
                    .font(SVFont.body(12))
                    .foregroundStyle(SVColor.textPrimary)
            }
            Text("·").foregroundStyle(SVColor.textSecondary.opacity(0.5))
            Text(appState.latencyMs.map { "\($0) ms" } ?? "— ms")
                .font(SVFont.mono(12))
                .foregroundStyle(SVColor.textPrimary)
            Text("·").foregroundStyle(SVColor.textSecondary.opacity(0.5))
            Text("\(appState.serverUptimeShort) uptime")
                .font(SVFont.mono(12))
                .foregroundStyle(SVColor.textPrimary)
        }
    }

    /// Shown when online — read-only URL + username + Sign Out.
    private var serverCard: some View {
        SVCard {
            infoRow(label: "URL", value: appState.serverURL.isEmpty ? "—" : appState.serverURL, action: nil)
            infoRow(label: "Signed in as",
                    value: appState.username.isEmpty ? "—" : appState.username,
                    action: "Sign Out", isLast: true) {
                Task { await appState.signOut() }
            }
        }
    }

    /// Shown when offline — editable URL + Username + Password + Sign In button.
    /// All three are editable so the user can switch servers, fix a typo, or
    /// recover after a Sign Out without going through onboarding again.
    private var signInCard: some View {
        SVCard {
            fieldRow(label: "URL",
                     text: $signInURL,
                     placeholder: "https://sync.example.com",
                     isSecure: false)
            fieldRow(label: "Username",
                     text: $signInUsername,
                     placeholder: "username",
                     isSecure: false)
            fieldRow(label: "Password",
                     text: $signInPassword,
                     placeholder: "password",
                     isSecure: true,
                     submit: performSignIn)

            SVCardRow(isLast: true) {
                HStack {
                    if let err = signInError {
                        Text(err)
                            .font(SVFont.body(11))
                            .foregroundStyle(SVColor.accentRed)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button(signingIn ? "Signing in…" : "Sign In") {
                        performSignIn()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SVColor.accentBlue)
                    .disabled(signingIn
                              || signInPassword.isEmpty
                              || signInURL.isEmpty
                              || signInUsername.isEmpty)
                }
            }
        }
        .onAppear {
            // Hydrate once with whatever's already in config (typically the URL +
            // username from the last successful login). Don't reset on every appear
            // or we'd wipe what the user typed when switching tabs.
            guard !hydratedFields else { return }
            signInURL = appState.serverURL
            signInUsername = appState.username
            hydratedFields = true
        }
    }

    /// Compact row matching the look of `infoRow`: label on the left, an inline
    /// text field filling the rest of the row. Wraps in SVCardRow so the
    /// auto-hairline divider between rows is consistent with the other cards.
    private func fieldRow(label: String,
                          text: Binding<String>,
                          placeholder: String,
                          isSecure: Bool,
                          submit: @escaping () -> Void = {}) -> some View {
        SVCardRow {
            HStack(spacing: SVSpacing.xl) {
                Text(label)
                    .font(SVFont.body(12))
                    .foregroundStyle(SVColor.textSecondary)
                    .frame(width: 140, alignment: .leading)
                Group {
                    if isSecure {
                        SecureField(placeholder, text: text)
                    } else {
                        TextField(placeholder, text: text)
                            .textContentType(label == "URL" ? .URL : (label == "Username" ? .username : nil))
                            .autocorrectionDisabled()
                    }
                }
                .textFieldStyle(.plain)
                .font(SVFont.mono(12))
                .disabled(signingIn)
                .onSubmit(submit)
            }
        }
    }

    private func performSignIn() {
        let url = signInURL.trimmingCharacters(in: .whitespaces)
        let user = signInUsername.trimmingCharacters(in: .whitespaces)
        let pw = signInPassword
        guard !pw.isEmpty, !url.isEmpty, !user.isEmpty, !signingIn else { return }
        signingIn = true
        signInError = nil
        Task {
            do {
                try await appState.connect(url: url, username: user, password: pw)
                await MainActor.run {
                    signInPassword = ""
                    signingIn = false
                }
            } catch {
                await MainActor.run {
                    signInError = error.localizedDescription
                    signingIn = false
                }
            }
        }
    }

    /// Server / Client version cards — push-protocol row removed; it lives in
    /// the live-health "Status" card at the top of the page now.
    private var versionsCard: some View {
        SVCard {
            infoRow(label: "Server", value: appState.serverVersion ?? "—",
                    trailingPill: appState.serverVersion != nil ? "connected" : "—",
                    pillKind: appState.serverVersion != nil ? .live : .neutral)
            infoRow(label: "Client (this Mac)", value: Bundle.main.shortVersion,
                    trailingPill: "running", isLast: true)
        }
    }

    private var deviceCard: some View {
        SVCard {
            infoRow(label: "Name", value: Host.current().localizedName ?? "This Mac", action: nil)
            infoRow(label: "Device ID",
                    value: appState.deviceID.isEmpty ? "—" : (String(appState.deviceID.prefix(13)) + "…"),
                    action: "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(appState.deviceID, forType: .string)
            }
            infoRow(label: "Registered", value: appState.deviceRegisteredDateFormatted, action: nil, isLast: true)
        }
    }

    private func infoRow(label: String, value: String, action: String? = nil,
                         trailingPill: String? = nil,
                         pillKind: SVStatusPill.Kind = .neutral,
                         isLast: Bool = false,
                         perform: (() -> Void)? = nil) -> some View {
        SVCardRow(isLast: isLast) {
            HStack(spacing: SVSpacing.xl) {
                Text(label)
                    .font(SVFont.body(12))
                    .foregroundStyle(SVColor.textSecondary)
                    .frame(width: 140, alignment: .leading)
                Text(value)
                    .font(SVFont.mono(12))
                    .foregroundStyle(SVColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let p = trailingPill {
                    SVStatusPill(text: p, kind: pillKind)
                }
                if let a = action {
                    Button(a) { perform?() }
                        .buttonStyle(.plain)
                        .font(SVFont.body(12))
                        .foregroundStyle(SVColor.accentBlue)
                }
            }
        }
    }
}

// MARK: - Labeled Field Helper (used by SyncTasksTab)

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
