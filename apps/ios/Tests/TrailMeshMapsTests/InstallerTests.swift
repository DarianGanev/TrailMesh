import XCTest
@testable import TrailMeshMaps

private struct FixtureTransport: PackTransport {
    let files: [String: Data]
    let cancel: Bool
    func fetch(url: URL, destination: URL, expectedBytes: Int64, cancellation: InstallCancellation) async throws {
        if cancel { cancellation.cancel() }
        try cancellation.check()
        try XCTUnwrap(files[url.lastPathComponent]).write(to: destination)
    }
}

private actor PausedFixtureTransport: PackTransport {
    let files: [String: Data]
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resume: CheckedContinuation<Void, Never>?
    init(files: [String: Data]) { self.files = files }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() { resume?.resume(); resume = nil }
    func fetch(url: URL, destination: URL, expectedBytes: Int64, cancellation: InstallCancellation) async throws {
        if !started {
            await withCheckedContinuation { continuation in
                resume = continuation; started = true
                startWaiters.forEach { $0.resume() }; startWaiters.removeAll()
            }
        }
        try cancellation.check()
        try XCTUnwrap(files[url.lastPathComponent]).write(to: destination)
    }
}

final class InstallerTests: XCTestCase {
    func testStoresForAliasedRootShareInstallationAndLeases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("unused/..")
        let first = RegionStore(root: root), second = RegionStore(root: alias)
        let (data, files) = try fixture(), hash = RegionManifest.digest(data)
        let transport = PausedFixtureTransport(files: files)
        let releaseURL = try XCTUnwrap(URL(string: "https://example.com/release/"))
        let operation = Task { try await first.install(manifestData: data, expectedSHA256: hash, releaseDirectory: releaseURL, transport: transport) }
        await transport.waitUntilStarted()
        do {
            _ = try await second.install(manifestData: data, expectedSHA256: hash, releaseDirectory: releaseURL, transport: FixtureTransport(files: files, cancel: false))
            XCTFail("same revision must not write staging from a second store")
        } catch { XCTAssertEqual(error as? MapFailure, .busy) }
        await transport.release()
        let installed = try await operation.value
        let reopened = try await second.openInstalled(id: "rila", revision: "v1", expectedSHA256: hash)
        XCTAssertEqual(reopened.manifest.key, installed.manifest.key)
        do {
            _ = try await second.openInstalled(id: "rila", revision: "v1", expectedSHA256: String(repeating: "0", count: 64))
            XCTFail("offline reopen must enforce the catalog pin")
        } catch { XCTAssertEqual(error as? MapFailure, .corrupt) }
        do {
            _ = try await second.openInstalled(id: "../rila", revision: "v1", expectedSHA256: hash)
            XCTFail("offline reopen must reject unsafe identifiers")
        } catch { XCTAssertEqual(error as? MapFailure, .corrupt) }
        let lease = try await first.lease(installed)
        do { try await second.remove(installed); XCTFail("second store must observe graph lease") }
        catch { XCTAssertEqual(error as? MapFailure, .busy) }
        lease.close()
        try await second.remove(installed)
        do { _ = try await first.lease(installed); XCTFail("removed pack cannot be leased") }
        catch { XCTAssertEqual(error as? MapFailure, .unavailable) }
        _ = try await second.install(manifestData: data, expectedSHA256: hash, releaseDirectory: releaseURL, transport: FixtureTransport(files: files, cancel: false))
    }
    private func fixture() throws -> (Data, [String: Data]) {
        var archive = Data(repeating: 0, count: 127)
        archive.replaceSubrange(0..<8, with: Array("PMTiles".utf8) + [3])
        archive[24] = 127; archive[32] = 2; archive[97] = 1; archive[98] = 1
        archive.append(Data("{}".utf8))
        let files = ["map.pmtiles": archive, "routing.tar": Data([2]), "places.json": Data(#"{"format":1,"places":[]}"#.utf8),
                     "style.json": Data(#"{"version":8,"sources":{"map":{"type":"vector","url":"pmtiles://{PACK_ROOT}/map.pmtiles"}},"layers":[]}"#.utf8), "licenses/OSM.txt": Data("OSM".utf8)]
        let entries: [[String: Any]] = files.sorted(by: { $0.key < $1.key }).map { ["path": $0.key, "asset": $0.key.replacingOccurrences(of: "/", with: "-"), "bytes": $0.value.count, "sha256": RegionManifest.digest($0.value)] }
        let object: [String: Any] = ["format": 1, "id": "rila", "revision": "v1", "name": "Rila", "dataDate": "2026-11-17", "boundsE7": [220000000,410000000,250000000,430000000], "minZoom": 0, "maxZoom": 14, "engine": "valhalla-3.9.2", "attribution": "OpenStreetMap contributors", "files": entries]
        return (try JSONSerialization.data(withJSONObject: object), Dictionary(uniqueKeysWithValues: files.map { ($0.key.replacingOccurrences(of: "/", with: "-"), $0.value) }))
    }
    func testInstallRevalidateTamperAndLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (data, files) = try fixture(), hash = RegionManifest.digest(data)
        let store = RegionStore(root: root)
        let installed = try await store.install(manifestData: data, expectedSHA256: hash, releaseDirectory: URL(string: "https://example.com/release/")!, transport: FixtureTransport(files: files, cancel: false))
        let lease = try await store.lease(installed)
        do { try await store.remove(installed); XCTFail("must be busy") } catch { XCTAssertEqual(error as? MapFailure, .busy) }
        lease.close()
        try Data([9]).write(to: installed.root.appendingPathComponent("routing.tar"))
        do { _ = try await store.verify(root: installed.root, expectedSHA256: hash); XCTFail("tampered graph") } catch {}
        try await store.remove(installed)
    }
    func testCancellationCannotPublishAndMatchingStagingResumes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (data, files) = try fixture(), hash = RegionManifest.digest(data)
        let store = RegionStore(root: root)
        do {
            _ = try await store.install(manifestData: data, expectedSHA256: hash, releaseDirectory: URL(string: "https://example.com/release/")!, transport: FixtureTransport(files: files, cancel: true))
            XCTFail("cancelled")
        } catch { XCTAssertEqual(error as? MapFailure, .cancelled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("rila/v1").path))
        _ = try await store.install(manifestData: data, expectedSHA256: hash, releaseDirectory: URL(string: "https://example.com/release/")!, transport: FixtureTransport(files: files, cancel: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("rila/v1/manifest.json").path))
    }
    func testWrongManifestHashAndDuplicateDecodedKeysReject() throws {
        let (data, _) = try fixture()
        XCTAssertThrowsError(try RegionManifest.parse(data, expectedSHA256: String(repeating: "0", count: 64)))
        let duplicate = Data(#"{"format":1,"format":1}"#.utf8)
        XCTAssertThrowsError(try RegionManifest.parse(duplicate, expectedSHA256: RegionManifest.digest(duplicate)))
    }
}
