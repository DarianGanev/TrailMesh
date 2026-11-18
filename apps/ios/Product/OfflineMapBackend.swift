import Foundation
import MapLibre
import TrailMeshNativeRouting
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
    private var engine: OfflineNativeRouter?
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
                    let encoded = try OfflineNativeRouter.configuration(tileExtract: region.root.appendingPathComponent("routing.tar"))
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("trailmesh-routing-\(UUID().uuidString).json")
                    try encoded.write(to: url, options: .atomic)
                    do { engine = try OfflineNativeRouter(configPath: url.path) }
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
                    let response: Data
                    do { response = try engine.route(rawRequest: request) }
                    catch { throw MapFailure.noRoute }
                    let route = try HikingRoute.parse(response, from: from, to: to)
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
    private var pending: (id: UUID, continuation: CheckedContinuation<UIImage, Error>)?
    var isRendering: Bool { pending != nil }

    func render(region: InstalledRegion, lease: PackLease, center: MapPoint, zoom: Double = 13) async throws -> UIImage {
        guard !isRendering else { lease.close(); throw MapFailure.busy }
        defer { lease.close() }
        try Task.checkCancellation()
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
        let id = UUID()
        let image = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
                let worker = MLNMapSnapshotter(options: options)
                snapshotter = worker
                pending = (id, continuation)
                worker.start { [weak self] snapshot, error in
                    Task { @MainActor in
                        if let error { self?.finish(id, with: .failure(error)) }
                        else if let snapshot { self?.finish(id, with: .success(snapshot.image)) }
                        else { self?.finish(id, with: .failure(MapFailure.corrupt)) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(id, with: .failure(CancellationError())) }
        }
        try Task.checkCancellation()
        return image
    }

    private func finish(_ id: UUID, with result: Result<UIImage, Error>) {
        guard let active = pending, active.id == id else { return }
        pending = nil
        // MapLibre 7.0.0 synchronously destroys the native snapshotter in cancel().
        // Tear it down before resuming the caller and releasing its pack lease.
        snapshotter?.cancel()
        snapshotter = nil
        active.continuation.resume(with: result)
    }
}
