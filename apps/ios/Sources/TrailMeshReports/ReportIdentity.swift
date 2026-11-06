import CryptoKit
import Foundation
import Security

protocol IdentityKeyStore {
    func load() throws -> Data?
    func saveNew(_ bytes: Data) throws
}

public enum IdentityError: Error {
    case missing
    case alreadyExists
    case invalid
    case keychain(OSStatus)
}

public struct ReportIdentity: Sendable {
    private let key: Curve25519.Signing.PrivateKey
    public var publicKey: Data { key.publicKey.rawRepresentation }

    public static func create(store: KeychainIdentityStore) throws -> ReportIdentity {
        try create(store: store as any IdentityKeyStore)
    }

    static func create(store: any IdentityKeyStore) throws -> ReportIdentity {
        guard try store.load() == nil else { throw IdentityError.alreadyExists }
        let key = Curve25519.Signing.PrivateKey()
        try store.saveNew(key.rawRepresentation)
        return ReportIdentity(key: key)
    }

    public static func load(store: KeychainIdentityStore) throws -> ReportIdentity {
        try load(store: store as any IdentityKeyStore)
    }

    static func load(store: any IdentityKeyStore) throws -> ReportIdentity {
        guard let raw = try store.load() else { throw IdentityError.missing }
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { throw IdentityError.invalid }
        return ReportIdentity(key: key)
    }

    func sign(_ message: Data) throws -> Data { try key.signature(for: message) }
}

/// Stores the CryptoKit key representation in the device Keychain, never in SQLite.
public struct KeychainIdentityStore: IdentityKeyStore {
    private let service: String
    private let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw IdentityError.keychain(status) }
        guard let bytes = item as? Data else { throw IdentityError.invalid }
        return bytes
    }

    func saveNew(_ bytes: Data) throws {
        var item = query
        item[kSecValueData as String] = bytes
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem { throw IdentityError.alreadyExists }
        guard status == errSecSuccess else { throw IdentityError.keychain(status) }
    }
}
