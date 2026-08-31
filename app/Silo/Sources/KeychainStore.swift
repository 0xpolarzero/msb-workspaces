import Foundation
import Security

struct KeychainItem: Sendable, Equatable {
    let service: String
    let account: String
    let secret: Data
}

enum KeychainStoreError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(OSStatus)
    case itemNotFound
    case malformedItem

    var errorDescription: String? {
        switch self {
        case .unavailable(let status): return "The Mac Keychain rejected the requested credential operation (\(status))."
        case .itemNotFound: return "The requested credential was not found in the Mac Keychain."
        case .malformedItem: return "The Mac Keychain returned malformed credential data."
        }
    }
}

/// Stores only opaque credential material in Keychain. Workspace metadata is
/// intentionally kept separately so it can be migrated without touching secrets.
final class KeychainStore: @unchecked Sendable {
    private let accessGroup: String?

    init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    func save(_ item: KeychainItem) throws {
        var query = baseQuery(service: item.service, account: item.account)
        let attributes: [CFString: Any] = [
            kSecValueData: item.secret,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainStoreError.unavailable(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainStoreError.unavailable(status)
        }
    }

    func load(service: String, account: String) throws -> Data {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw KeychainStoreError.itemNotFound }
        guard status == errSecSuccess else { throw KeychainStoreError.unavailable(status) }
        guard let data = result as? Data else { throw KeychainStoreError.malformedItem }
        return data
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unavailable(status)
        }
    }

    func contains(service: String, account: String) -> Bool {
        do {
            _ = try load(service: service, account: account)
            return true
        } catch {
            return false
        }
    }

    private func baseQuery(service: String, account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        return query
    }
}
protocol CredentialKeychainStoring: Sendable {
    func save(_ item: KeychainItem) throws
    func load(service: String, account: String) throws -> Data
    func delete(service: String, account: String) throws
}

extension KeychainStore: CredentialKeychainStoring {}


/// One-way startup cleanup for a credential that earlier builds issued
/// directly. The secret is never read, decoded, or migrated: it is deleted
/// before credential-backed UI becomes available.
enum LegacyDirectGitHubCredentialRetirement {
    static let service = "org.microsandbox.Silo.github-device-session"
    static let account = "session"

    static func remove(using keychain: any CredentialKeychainStoring = KeychainStore()) throws {
        do {
            try keychain.delete(service: service, account: account)
        } catch {
            throw LegacyDirectGitHubCredentialRetirementError.removalUnconfirmed
        }
    }
}

enum LegacyDirectGitHubCredentialRetirementError: Error, LocalizedError, Sendable, Equatable {
    case removalUnconfirmed

    var errorDescription: String? {
        "GitHub access could not be secured. Restart Silo and try again."
    }
}

extension KeychainStore: MSWConnectKeychainStoring {}
