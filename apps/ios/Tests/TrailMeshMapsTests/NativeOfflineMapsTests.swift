#if os(iOS)
import XCTest
import TrailMeshMaps
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
            do { try await store.remove(region); XCTFail("graph lease must block removal") }
            catch { XCTAssertEqual(error as? MapFailure, .busy) }
            await router.close()
        }
        let snapshot = OfflineMapSnapshot()
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
}
#endif
