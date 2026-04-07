import Foundation
import Security
import CryptoKit
import CommonCrypto

enum KeychainHelper {
    private static let accessGroup = "DE59N86W33.com.syncvault.shared"
    private static let service = "com.syncvault.app"

    static func save(key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Shared keychain (accessible by app group / File Provider extension)

    /// Saves a value to the shared keychain accessible by the app group.
    /// The access group must match the App Group entitlement (DE59N86W33.com.syncvault.shared).
    static func saveShared(key: String, value: String) {
        let data = value.data(using: .utf8)!
        // Use standard keychain with access group — works reliably across app and extension
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: "com.syncvault.shared",
            kSecAttrAccessGroup as String: "DE59N86W33.com.syncvault.shared"
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func loadShared(key: String) -> String? {
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

// MARK: - Connection Token Handling

struct ConnectionData: Codable {
    let serverURL: String
    let username: String
    let password: String

    enum CodingKeys: String, CodingKey {
        case serverURL = "server_url"
        case username
        case password
    }
}

enum TokenError: Error, LocalizedError {
    case invalidToken
    case invalidPIN
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidToken:  return "Invalid token file"
        case .invalidPIN:    return "Incorrect PIN"
        case .decodingFailed: return "Failed to decode connection data"
        }
    }
}

struct TokenHandler {
    private static func deriveKey(pin: String) -> Data {
        let password = pin.data(using: .utf8)!
        let salt = "syncvault-token".data(using: .utf8)!
        var derivedKey = Data(count: 32)

        derivedKey.withUnsafeMutableBytes { derivedKeyPtr in
            password.withUnsafeBytes { passwordPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress!.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        100_000,
                        derivedKeyPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        return derivedKey
    }

    static func decrypt(data: Data, pin: String) throws -> ConnectionData {
        let nonceSize = 12
        let tagSize = 16

        guard data.count > nonceSize + tagSize else {
            throw TokenError.invalidToken
        }

        let keyData = deriveKey(pin: pin)
        let key = SymmetricKey(data: keyData)

        let nonce = try AES.GCM.Nonce(data: data.prefix(nonceSize))
        let ciphertext = data.dropFirst(nonceSize).dropLast(tagSize)
        let tag = data.suffix(tagSize)

        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)

        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw TokenError.invalidPIN
        }

        do {
            return try JSONDecoder().decode(ConnectionData.self, from: plaintext)
        } catch {
            throw TokenError.decodingFailed
        }
    }
}
