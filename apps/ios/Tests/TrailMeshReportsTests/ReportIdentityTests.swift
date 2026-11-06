import CryptoKit
import Foundation
import Security
import XCTest
@testable import TrailMeshReports

final class ReportIdentityTests: XCTestCase {
    func testIdentityIsStableAndSignsAfterReload() throws {
        let storage = TestIdentityStore()
        let created = try ReportIdentity.create(store: storage)
        let loaded = try ReportIdentity.load(store: storage)
        XCTAssertEqual(created.publicKey, loaded.publicKey)
        let message = Data("TrailMesh identity test".utf8)
        let signature = try loaded.sign(message)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: created.publicKey)
        XCTAssertTrue(key.isValidSignature(signature, for: message))
        XCTAssertThrowsError(try ReportIdentity.create(store: storage))
    }

    func testMissingOrDeniedKeyNeverCreatesReplacement() throws {
        let missing = TestIdentityStore()
        XCTAssertThrowsError(try ReportIdentity.load(store: missing))
        XCTAssertNil(missing.value)
        let denied = TestIdentityStore()
        denied.denied = true
        XCTAssertThrowsError(try ReportIdentity.load(store: denied))
        XCTAssertThrowsError(try ReportIdentity.create(store: denied))
        XCTAssertNil(denied.value)
    }

    func testKeychainIdentityPersistsAcrossStoreInstances() throws {
        let service = "org.trailmesh.tests." + UUID().uuidString
        let account = "report-identity"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        defer { SecItemDelete(query as CFDictionary) }
        let first = KeychainIdentityStore(service: service, account: account)
        let second = KeychainIdentityStore(service: service, account: account)
        let created = try ReportIdentity.create(store: first)
        let loaded = try ReportIdentity.load(store: second)
        XCTAssertEqual(created.publicKey, loaded.publicKey)
        XCTAssertThrowsError(try ReportIdentity.create(store: second))
    }

    func testInvalidKeyMaterialDoesNotCreateReplacement() throws {
        let storage = TestIdentityStore()
        storage.value = Data([1, 2, 3])
        XCTAssertThrowsError(try ReportIdentity.load(store: storage))
        XCTAssertThrowsError(try ReportIdentity.create(store: storage))
        XCTAssertEqual(storage.value, Data([1, 2, 3]))
    }

}

private final class TestIdentityStore: IdentityKeyStore {
    enum Denied: Error { case access }
    var value: Data?
    var denied = false
    func load() throws -> Data? {
        if denied { throw Denied.access }
        return value
    }
    func saveNew(_ bytes: Data) throws {
        if denied { throw Denied.access }
        guard value == nil else { throw IdentityError.alreadyExists }
        value = bytes
    }
}
