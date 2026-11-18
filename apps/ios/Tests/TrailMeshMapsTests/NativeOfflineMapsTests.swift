#if os(iOS)
import XCTest
import TrailMeshMaps
import TrailMeshReports
@testable import TrailMesh

final class NativeOfflineMapsTests: XCTestCase {
    private struct Smoke: Decodable { let from: MapPoint; let to: MapPoint; let query: String }
    @MainActor
    func testOfflineHTTPBlockerFailsClosed() async throws {
        OfflineHTTPBlocker.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineHTTPBlocker.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do { _ = try await session.data(from: URL(string: "https://example.invalid/must-not-reach-network")!); XCTFail("network must fail") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertEqual(OfflineHTTPBlocker.attempts, 1)
    }
    @MainActor
    func testRealGraphColdOpenRouteAndSnapshot() async throws {
        let environment = ProcessInfo.processInfo.environment
        let keys = ["TRAILMESH_MAP_PACK", "TRAILMESH_MAP_MANIFEST_SHA256"]
        guard keys.contains(where: { key in
            guard let value = environment[key] else { return false }
            return !value.isEmpty && value != "$(\(key))"
        }) else {
            throw XCTSkip("External generated real regional pack and pinned manifest hash required")
        }
        let path = try XCTUnwrap(environment["TRAILMESH_MAP_PACK"])
        let hash = try XCTUnwrap(environment["TRAILMESH_MAP_MANIFEST_SHA256"])
        guard path.hasPrefix("/"), !path.contains("$("), hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) == hash.startIndex..<hash.endIndex else {
            XCTFail("Supplied offline smoke configuration must contain an absolute pack path and lowercase SHA-256")
            throw MapFailure.corrupt
        }
        let external = URL(fileURLWithPath: path)
        let smoke = try JSONDecoder().decode(Smoke.self, from: Data(contentsOf: external.deletingLastPathComponent().appendingPathComponent("smoke.json")))
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("offline-map-smoke/\(hash)")
        let copy = root.appendingPathComponent("rila/fixture")
        let reopened = FileManager.default.fileExists(atPath: copy.path)
        if !reopened {
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: external, to: copy)
        }
        let installation = XCTAttachment(string: reopened ? "Reopened existing verified app-private pack" : "Copied external fixture into app-private storage")
        installation.name = "offline-pack-persistence"; installation.lifetime = .keepAlways; add(installation)
        let store = RegionStore(root: root)
        OfflineHTTPBlocker.reset()
        OfflineHTTPBlocker.configureRenderer()
        let region = try await store.verify(root: copy, expectedSHA256: hash)
        XCTAssertFalse(try PlaceIndex(data: Data(contentsOf: copy.appendingPathComponent("places.json"))).search(smoke.query).isEmpty)
        let router = OfflineHikingRouter()
        for _ in 0..<2 {
            try await router.open(region, lease: try await store.lease(region))
            let route = try await router.route(from: smoke.from, to: smoke.to)
            XCTAssertGreaterThan(route.points.count, 2)
            XCTAssertGreaterThan(route.distanceKm, 0)
            let context = RelevanceContext(route: try route.reportRelevance())
            let near = route.points[route.points.count / 2]
            let nearReport = RelevanceReport(id: "rila-route", observedAt: 100, expiresAt: 200, latitude: near.latE7, longitude: near.lonE7)
            let sofiaReport = RelevanceReport(id: "sofia", observedAt: 100, expiresAt: 200, latitude: 426977000, longitude: 233219000)
            XCTAssertEqual(RelevancePolicy.evaluate(nearReport, context: context, now: 100), .eligible)
            XCTAssertEqual(RelevancePolicy.evaluate(sofiaReport, context: context, now: 100), .notRelevant)
            do { try await store.remove(region); XCTFail("graph lease must block removal") }
            catch { XCTAssertEqual(error as? MapFailure, .busy) }
            await router.close()
        }
        let snapshot = OfflineMapSnapshot()
        await assertSnapshotCancellation(snapshot, region: region, center: smoke.to)
        let image = try await snapshot.render(region: region, lease: try await store.lease(region), center: smoke.to)
        let png = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(png.count, 10000, "Snapshot needs visual review for trails, labels and attribution")
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "rila-offline-native-snapshot"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(OfflineHTTPBlocker.attempts, 0, "A complete local pack must not attempt HTTP/HTTPS")
        // Keep the verified pack for a second invocation after process shutdown.
        // Core installer tests cover successful removal after releasing leases.
        _ = try await store.verify(root: copy, expectedSHA256: hash)
    }

    @MainActor
    private func assertSnapshotCancellation(_ snapshot: OfflineMapSnapshot, region: InstalledRegion, center: MapPoint) async {
        let leases = PackLeases()
        let key = region.manifest.id
        let completed = expectation(description: "Cancelled snapshot completes within its deadline")
        let task = Task { @MainActor in
            defer { completed.fulfill() }
            do {
                _ = try await snapshot.render(region: region, lease: leases.acquire(key), center: center)
                XCTFail("A cancelled snapshot must not return an image")
            } catch is CancellationError {
                XCTAssertFalse(snapshot.isRendering)
                XCTAssertNoThrow(try leases.withRemoval(key) {})
            } catch {
                XCTFail("Unexpected snapshot error: \(error)")
            }
        }
        for _ in 0..<100 where !snapshot.isRendering {
            await Task.yield()
        }
        XCTAssertTrue(snapshot.isRendering)
        XCTAssertThrowsError(try leases.withRemoval(key) {}) { XCTAssertEqual($0 as? MapFailure, .busy) }
        task.cancel()
        await fulfillment(of: [completed], timeout: 5)
    }

}
#endif
