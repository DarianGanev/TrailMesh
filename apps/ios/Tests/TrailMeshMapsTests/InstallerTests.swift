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

private actor FinalAssetCancellationTransport: PackTransport {
    let files: [String: Data]
    private var written = 0
    init(files: [String: Data]) { self.files = files }
    func fetch(url: URL, destination: URL, expectedBytes: Int64, cancellation: InstallCancellation) async throws {
        try XCTUnwrap(files[url.lastPathComponent]).write(to: destination)
        written += 1
        if written == files.count { cancellation.cancel() }
    }
}

private struct NoDownloadTransport: PackTransport {
    func fetch(url: URL, destination: URL, expectedBytes: Int64, cancellation: InstallCancellation) async throws {
        XCTFail("verified completed staging files should be reused")
        throw MapFailure.unavailable
    }
}

private final class StalledPackProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.path == "/body" {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "ETag": "\"body\"", "Content-Length": "131072"
            ])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 42, count: 65536))
        }
        // Signal a real started request even when withholding response headers.
        NotificationCenter.default.post(name: Notification.Name("StalledPackProtocol-\(url.path)"), object: nil)
    }
    override func stopLoading() {}
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
    func testInterruptedRetirementRecoversAndSameRevisionReinstalls() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let (data, files) = try fixture(), hash = RegionManifest.digest(data)
        let store = RegionStore(root: root)
        let release = URL(string: "https://example.com/release/")!
        let installed = try await store.install(manifestData: data, expectedSHA256: hash, releaseDirectory: release, transport: FixtureTransport(files: files, cancel: false))
        let trash = root.appendingPathComponent(".trash/interrupted")
        try fm.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Simulate death after atomic retirement and partway through deletion.
        try fm.moveItem(at: installed.root, to: trash)
        try fm.removeItem(at: trash.appendingPathComponent("routing.tar"))
        let restarted = RegionStore(root: root)
        let found = await restarted.discover(catalog: ["rila/v1": hash])
        XCTAssertTrue(found.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: trash.path))
        let replacement = try await restarted.install(manifestData: data, expectedSHA256: hash, releaseDirectory: release, transport: FixtureTransport(files: files, cancel: false))
        _ = try await restarted.verify(root: replacement.root, expectedSHA256: hash)
    }
    func testCleanupFailureAfterRemovalDoesNotStrandFinalRevision() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep")
        try Data([42]).write(to: sentinel)
        let (data, files) = try fixture(), hash = RegionManifest.digest(data)
        let store = RegionStore(root: root)
        let release = URL(string: "https://example.com/release/")!
        let installed = try await store.install(manifestData: data, expectedSHA256: hash, releaseDirectory: release, transport: FixtureTransport(files: files, cancel: false))
        // Force the no-follow cleanup check to fail after retirement.
        try fm.createSymbolicLink(at: installed.root.appendingPathComponent("escape"), withDestinationURL: outside)
        try await store.remove(installed)
        XCTAssertFalse(fm.fileExists(atPath: installed.root.path))
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: root.appendingPathComponent(".trash").path).isEmpty)
        _ = try await store.install(manifestData: data, expectedSHA256: hash, releaseDirectory: release, transport: FixtureTransport(files: files, cancel: false))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([42]))
    }
    func testTrashSymlinkNeverDeletesExternalDataOrBlocksReinstall() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        try fm.createDirectory(at: root.appendingPathComponent(".trash/interrupted"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep")
        try Data([42]).write(to: sentinel)
        try fm.createSymbolicLink(at: root.appendingPathComponent(".trash/interrupted/escape"), withDestinationURL: outside)
        let (data, files) = try fixture(), hash = RegionManifest.digest(data)
        let store = RegionStore(root: root)
        _ = try await store.install(manifestData: data, expectedSHA256: hash, releaseDirectory: URL(string: "https://example.com/release/")!, transport: FixtureTransport(files: files, cancel: false))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([42]))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent(".trash/interrupted/escape").path))
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
    func testCorruptRevisionCanBeRemovedByKeyAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (data, files) = try fixture(), hash = RegionManifest.digest(data)
        let release = URL(string: "https://example.com/release/")!
        let transport = FixtureTransport(files: files, cancel: false)
        let store = RegionStore(root: root)
        let installed = try await store.install(manifestData: data, expectedSHA256: hash, releaseDirectory: release, transport: transport)
        let lease = try await store.lease(installed)
        try FileManager.default.removeItem(at: installed.root.appendingPathComponent("routing.tar"))
        let restarted = RegionStore(root: root)
        let found = await restarted.discover(catalog: ["rila/v1": hash])
        XCTAssertTrue(found.isEmpty)
        do { try await restarted.remove(id: "rila", revision: "v1"); XCTFail("active lease must block retirement") }
        catch { XCTAssertEqual(error as? MapFailure, .busy) }
        lease.close()
        try await restarted.remove(id: "rila", revision: "v1")
        _ = try await restarted.install(manifestData: data, expectedSHA256: hash, releaseDirectory: release, transport: transport)
        _ = try await restarted.openInstalled(id: "rila", revision: "v1", expectedSHA256: hash)
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
    func testTokenCancelsStalledHTTPSBeforeHeadersAndDuringBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = HTTPSPackTransport {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StalledPackProtocol.self]
            return configuration
        }
        for phase in ["headers", "body"] {
            let url = try XCTUnwrap(URL(string: "https://example.com/\(phase)"))
            let destination = root.appendingPathComponent(phase)
            let cancellation = InstallCancellation()
            let started = expectation(forNotification: Notification.Name("StalledPackProtocol-/\(phase)"), object: nil)
            let finished = expectation(description: "cancelled \(phase) request completed")
            let operation = Task {
                defer { finished.fulfill() }
                try await transport.fetch(url: url, destination: destination, expectedBytes: 131072, cancellation: cancellation)
            }
            await fulfillment(of: [started], timeout: 5)
            if phase == "body" {
                var written: Int64 = 0
                for _ in 0..<100 {
                    let size = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber
                    written = size?.int64Value ?? 0
                    if written == 65536 { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertEqual(written, 65536, "the response must stall after a body chunk is written")
            }
            cancellation.cancel()
            await fulfillment(of: [finished], timeout: 5)
            operation.cancel()
            do { try await operation.value; XCTFail("token cancelled a stalled request") }
            catch { XCTAssertEqual(error as? MapFailure, .cancelled) }
        }
    }

    func testCancelAfterFinalAssetPreventsPublicationAndReusesStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (data, files) = try fixture(), hash = RegionManifest.digest(data)
        let url = try XCTUnwrap(URL(string: "https://example.com/release/"))
        let store = RegionStore(root: root)
        do {
            _ = try await store.install(manifestData: data, expectedSHA256: hash, releaseDirectory: url,
                                        transport: FinalAssetCancellationTransport(files: files))
            XCTFail("final asset cancellation must prevent publication")
        } catch { XCTAssertEqual(error as? MapFailure, .cancelled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("rila/v1").path))
        let installed = try await store.install(manifestData: data, expectedSHA256: hash, releaseDirectory: url,
                                                transport: NoDownloadTransport())
        _ = try await store.verify(root: installed.root, expectedSHA256: hash)
    }

    func testHikingRequestDisablesFerries() throws {
        let (data, _) = try fixture()
        let manifest = try RegionManifest.parse(data, expectedSHA256: RegionManifest.digest(data))
        let start = MapPoint(latE7: 420000000, lonE7: 230000000)
        let finish = MapPoint(latE7: 421000000, lonE7: 231000000)
        let request = try HikingRoute.request(from: start, to: finish, manifest: manifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        let options = try XCTUnwrap(object["costing_options"] as? [String: [String: Int]])
        XCTAssertEqual(options["pedestrian"], ["max_hiking_difficulty": 2, "use_ferry": 0])
        XCTAssertEqual(object["costing"] as? String, "pedestrian")
    }

    func testWrongManifestHashAndDuplicateDecodedKeysReject() throws {
        let (data, _) = try fixture()
        XCTAssertThrowsError(try RegionManifest.parse(data, expectedSHA256: String(repeating: "0", count: 64)))
        XCTAssertNoThrow(try RegionManifest.parse(data, expectedSHA256: RegionManifest.digest(data)))
        var duplicate = Data(#"{"\u0066ormat":1,"#.utf8)
        duplicate.append(data.dropFirst())
        XCTAssertThrowsError(try RegionManifest.parse(duplicate, expectedSHA256: RegionManifest.digest(duplicate)))
    }
}
