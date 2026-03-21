import Foundation

enum SharedConfig {
    // App Group ID — must match entitlements
    static let appGroupID = "TEAM_ID.com.syncvault.shared"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID)!
    }

    static func apiClient() throws -> APIClient {
        guard let url = sharedDefaults.string(forKey: "serverURL"),
              !url.isEmpty else {
            throw NSError(domain: "com.syncvault", code: 1, userInfo: [NSLocalizedDescriptionKey: "Server not configured. Open SyncVault app to set up."])
        }

        let client = APIClient(baseURL: url)

        // Load token from shared keychain (written by main app via KeychainHelper.saveShared)
        if let token = KeychainHelper.loadShared(key: "access_token") {
            // Set token on client
            Task { await client.setToken(token) }
        }

        return client
    }

    static func onDemandFolderID() -> String {
        return sharedDefaults.string(forKey: "onDemandFolderID") ?? ""
    }

    static func setOnDemandFolderID(_ id: String) {
        sharedDefaults.set(id, forKey: "onDemandFolderID")
    }
}
