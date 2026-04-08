import Foundation
import Security

enum SharedConfig {
    static let appGroupID = "DE59N86W33.com.syncvault.shared"
    private static let keychainService = "com.syncvault.shared"
    private static let keychainAccessGroup = "DE59N86W33.com.syncvault.shared"

    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID)!
    }

    // Singleton API client — prevents token race conditions between concurrent calls
    private static var _cachedClient: FPAPIClient?
    private static var _cachedClientURL: String?
    private static var _cachedClientCreated: Date?

    static func sharedClient() throws -> FPAPIClient {
        guard let url = sharedDefaults.string(forKey: "serverURL"), !url.isEmpty else {
            throw NSError(domain: "com.syncvault", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Server not configured"])
        }

        // Reuse client if URL matches and it's less than 24 hours old
        if let client = _cachedClient, _cachedClientURL == url,
           let created = _cachedClientCreated, Date().timeIntervalSince(created) < 86400 {
            return client
        }

        // Read fresh credentials from shared keychain
        let token = loadFromKeychain(key: "access_token")
        let username = loadFromKeychain(key: "fp_username")
        let password = loadFromKeychain(key: "fp_password")

        let client = FPAPIClient(baseURL: url, token: token, username: username, password: password)
        _cachedClient = client
        _cachedClientURL = url
        _cachedClientCreated = Date()
        return client
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

    // MARK: - Progress sharing (extension → app)

    static func setProgress(action: String, filename: String, bytesTransferred: Int64, totalBytes: Int64) {
        let defaults = sharedDefaults
        defaults.set(action, forKey: "fp_progress_action")
        defaults.set(filename, forKey: "fp_progress_filename")
        defaults.set(bytesTransferred, forKey: "fp_progress_bytes")
        defaults.set(totalBytes, forKey: "fp_progress_total")
        defaults.set(Date().timeIntervalSince1970, forKey: "fp_progress_timestamp")
    }

    static func clearProgress() {
        let defaults = sharedDefaults
        defaults.removeObject(forKey: "fp_progress_action")
        defaults.removeObject(forKey: "fp_progress_filename")
        defaults.removeObject(forKey: "fp_progress_bytes")
        defaults.removeObject(forKey: "fp_progress_total")
        defaults.removeObject(forKey: "fp_progress_timestamp")
    }

    // MARK: - Recent files (extension → app)

    static func addRecentFile(filename: String, action: String) {
        let defaults = sharedDefaults
        var recent = defaults.array(forKey: "fp_recent_files") as? [[String: String]] ?? []
        let entry: [String: String] = [
            "filename": filename,
            "action": action,
            "timestamp": "\(Date().timeIntervalSince1970)"
        ]
        recent.insert(entry, at: 0)
        if recent.count > 20 { recent = Array(recent.prefix(20)) }
        defaults.set(recent, forKey: "fp_recent_files")
    }

    static func getProgress() -> (action: String, filename: String, bytes: Int64, total: Int64, timestamp: Double)? {
        let defaults = sharedDefaults
        guard let action = defaults.string(forKey: "fp_progress_action"),
              let filename = defaults.string(forKey: "fp_progress_filename") else { return nil }
        let bytes = Int64(defaults.integer(forKey: "fp_progress_bytes"))
        let total = Int64(defaults.integer(forKey: "fp_progress_total"))
        let timestamp = defaults.double(forKey: "fp_progress_timestamp")
        // Stale if older than 30 seconds
        if Date().timeIntervalSince1970 - timestamp > 30 { return nil }
        return (action, filename, bytes, total, timestamp)
    }

    // MARK: - Keychain

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
