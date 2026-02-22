import Foundation
import Security

/// Secure Keychain storage, keyed per server environment (Production / Sandbox).
/// Each environment gets its own Keychain items so credentials never bleed across.
final class KeychainService {

    static let shared = KeychainService()
    private init() {}

    private let service = "com.karthikmac.JamfSearchScriptsEAs"

    // MARK: - Keys (scoped per environment)

    enum CredentialKey {
        case jamfURL(ServerEnvironment)
        case clientID(ServerEnvironment)
        case clientSecret(ServerEnvironment)

        var account: String {
            switch self {
            case .jamfURL(let env):       return "\(env.keychainPrefix).jamfURL"
            case .clientID(let env):      return "\(env.keychainPrefix).clientID"
            case .clientSecret(let env):  return "\(env.keychainPrefix).clientSecret"
            }
        }
    }

    // MARK: - Save

    @discardableResult
    func save(_ value: String, for key: CredentialKey) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        delete(key)

        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     key.account,
            kSecValueData as String:       data,
            kSecAttrAccessible as String:  kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Load

    func load(_ key: CredentialKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key.account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    // MARK: - Delete

    @discardableResult
    func delete(_ key: CredentialKey) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  key.account
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// Removes all credentials for a specific environment.
    func deleteAll(for env: ServerEnvironment) {
        delete(.jamfURL(env))
        delete(.clientID(env))
        delete(.clientSecret(env))
    }
}
