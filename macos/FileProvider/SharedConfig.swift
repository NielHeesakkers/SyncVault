import Foundation
import Security

enum SharedConfig {
    static let appGroupID = "DE59N86W33.com.syncvault.shared"
    private static let keychainService = "com.syncvault.shared"
    private static let keychainAccessGroup = "DE59N86W33.com.syncvault.shared"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID)!
    }

    static func apiClient() throws -> FPAPIClient {
        guard let url = sharedDefaults.string(forKey: "serverURL"), !url.isEmpty else {
            throw NSError(domain: "com.syncvault", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Server not configured"])
        }

        let token = loadFromKeychain(key: "access_token")
        let username = loadFromKeychain(key: "fp_username")
        let password = loadFromKeychain(key: "fp_password")

        return FPAPIClient(baseURL: url, token: token, username: username, password: password)
    }

    static func onDemandFolderID() -> String {
        return sharedDefaults.string(forKey: "onDemandFolderID") ?? ""
    }

    // MARK: - Keychain

    static func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: keychainService,
            kSecAttrAccessGroup as String: keychainAccessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveToKeychain(key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: keychainService,
            kSecAttrAccessGroup as String: keychainAccessGroup
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
