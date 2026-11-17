import Foundation
import MapLibre
import Valhalla
import ValhallaConfigModels
import UIKit
import TrailMeshMaps
import TrailMeshReports

/// The offline renderer's NSURLSession actively rejects network requests. The
/// counter is diagnostic evidence: missing resources must not hide in fallback.
final class OfflineHTTPBlocker: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    static var attempts: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func reset() { lock.lock(); count = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { ["http", "https"].contains(request.url?.scheme ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
    @MainActor static func configureRenderer() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineHTTPBlocker.self]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = configuration
    }
}

/// Native actor construction, synchronous routing and close all run on this
/// private serial queue, never the main thread. The graph lease outlives close.
final class OfflineHikingRouter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.trailmesh.offline-routing", qos: .userInitiated)
    private var engine: Valhalla?
    private var lease: PackLease?
    private var region: InstalledRegion?
    private var configURL: URL?
    func open(_ region: InstalledRegion, lease: PackLease) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    closeOnQueue()
                    // Start from the pinned engine defaults, then strip every network
                    // input before handing the JSON to the native parser.
                    let defaults = try ValhallaConfig(tileExtractTar: region.root.appendingPathComponent("routing.tar"))
                    let encoded = try JSONEncoder().encode(defaults)
                    guard var config = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                          var mjolnir = config["mjolnir"] as? [String: Any] else { throw MapFailure.invalidEngine }
                    mjolnir.removeValue(forKey: "tile_url")
                    mjolnir.removeValue(forKey: "tile_url_gz")
                    mjolnir.removeValue(forKey: "tile_dir")
                    mjolnir["tile_extract"] = region.root.appendingPathComponent("routing.tar").path
                    config["mjolnir"] = mjolnir
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("trailmesh-routing-\(UUID().uuidString).json")
                    try JSONSerialization.data(withJSONObject: config).write(to: url, options: .atomic)
                    do { engine = try Valhalla(configPath: url.path) }
                    catch { try? FileManager.default.removeItem(at: url); throw MapFailure.invalidEngine }
                    self.region = region; self.lease = lease; self.configURL = url
                    continuation.resume()
                } catch { lease.close(); continuation.resume(throwing: error) }
            }
        }
    }
    func route(from: MapPoint, to: MapPoint) async throws -> HikingRoute {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let region, let engine else { throw MapFailure.unavailable }
                    let request = try HikingRoute.request(from: from, to: to, manifest: region.manifest)
                    let response: String
                    do { response = try engine.route(rawRequest: request) }
                    catch { throw MapFailure.noRoute }
                    let route = try HikingRoute.parse(Data(response.utf8), from: from, to: to)
                    try route.validateCoverage(region.manifest)
                    continuation.resume(returning: route)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func close() async {
        await withCheckedContinuation { continuation in queue.async { [self] in closeOnQueue(); continuation.resume() } }
    }
    private func closeOnQueue() {
        engine?.close(); engine = nil; region = nil
        lease?.close(); lease = nil
        if let configURL { try? FileManager.default.removeItem(at: configURL) }; configURL = nil
    }
    deinit {
        // The object is captured by every queued operation; no inflight call
        // remains when deinit starts. Destruction still uses the serial queue.
        let engine = engine, lease = lease, configURL = configURL
        queue.async { engine?.close(); lease?.close(); if let configURL { try? FileManager.default.removeItem(at: configURL) } }
    }
}

extension HikingRoute {
    func reportRelevance(corridor: Int64 = 1000) throws -> RelevanceRoute {
        RelevanceRoute(points: try relevancePoints().map { RelevancePoint(latitude: $0.latE7, longitude: $0.lonE7) }, corridor: corridor)
    }
}

@MainActor
final class OfflineMapSnapshot {
    private var snapshotter: MLNMapSnapshotter?
    private var lease: PackLease?
    func render(region: InstalledRegion, lease: PackLease, center: MapPoint, zoom: Double = 13) async throws -> UIImage {
        guard snapshotter == nil else { lease.close(); throw MapFailure.busy }
        self.lease = lease
        defer { snapshotter = nil; self.lease?.close(); self.lease = nil }
        OfflineHTTPBlocker.configureRenderer()
        let style = try LocalStyle.resolve(Data(contentsOf: region.root.appendingPathComponent("style.json")), root: region.root, files: Set(region.manifest.files.map(\.path)))
        let runtime = FileManager.default.temporaryDirectory.appendingPathComponent("trailmesh-style-\(UUID().uuidString).json")
        try style.write(to: runtime, options: .atomic)
        defer { try? FileManager.default.removeItem(at: runtime) }
        let coordinate = CLLocationCoordinate2D(latitude: Double(center.latE7) / 1e7, longitude: Double(center.lonE7) / 1e7)
        let camera = MLNMapCamera(lookingAtCenter: coordinate, altitude: 4000, pitch: 0, heading: 0)
        let options = MLNMapSnapshotOptions(styleURL: runtime, camera: camera, size: CGSize(width: 1024, height: 768))
        options.zoomLevel = zoom
        options.showsAttribution = true
        let worker = MLNMapSnapshotter(options: options)
        snapshotter = worker
        return try await withCheckedThrowingContinuation { continuation in
            worker.start { snapshot, error in
                if let error { continuation.resume(throwing: error) }
                else if let snapshot { continuation.resume(returning: snapshot.image) }
                else { continuation.resume(throwing: MapFailure.corrupt) }
            }
        }
    }
}
