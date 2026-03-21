import Foundation
import Security

enum SharedConfig {
    // App Group ID — must match entitlements
    static let appGroupID = "DE59N86W33.com.syncvault.shared"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID)!
    }

    static func apiClient() throws -> FPAPIClient {
        guard let url = sharedDefaults.string(forKey: "serverURL"),
              !url.isEmpty else {
            throw NSError(domain: "com.syncvault", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Server not configured. Open SyncVault app to set up."])
        }

        // Load token from shared keychain (written by main app via KeychainHelper.saveShared)
        let token = loadFromKeychain(key: "access_token")
        return FPAPIClient(baseURL: url, token: token)
    }

    static func onDemandFolderID() -> String {
        return sharedDefaults.string(forKey: "onDemandFolderID") ?? ""
    }

    static func setOnDemandFolderID(_ id: String) {
        sharedDefaults.set(id, forKey: "onDemandFolderID")
    }

    // MARK: - Inline keychain access (shared keychain accessible by app group)

    static func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.syncvault.shared",
            kSecAttrAccessGroup as String: "DE59N86W33.com.syncvault.shared",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
