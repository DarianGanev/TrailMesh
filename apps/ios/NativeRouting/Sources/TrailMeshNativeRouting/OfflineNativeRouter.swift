import Foundation
import TrailMeshValhalla

public enum NativeRoutingFailure: Error { case configuration, engine, response }

/// Caller must serialize construction, route and close, including final release.
/// The product adapter owns its serial queue and graph lease.
public final class OfflineNativeRouter: @unchecked Sendable {
    private var actor: UnsafeMutableRawPointer?
    public static func configuration(tileExtract: URL) throws -> Data {
        guard tileExtract.isFileURL, tileExtract.path.hasPrefix("/"),
              let defaults = Bundle.module.url(forResource: "default", withExtension: "json"),
              var config = try JSONSerialization.jsonObject(with: Data(contentsOf: defaults)) as? [String: Any],
              var mjolnir = config["mjolnir"] as? [String: Any] else { throw NativeRoutingFailure.configuration }
        mjolnir.removeValue(forKey: "tile_url")
        mjolnir.removeValue(forKey: "tile_url_gz")
        mjolnir.removeValue(forKey: "tile_dir")
        mjolnir["tile_extract"] = tileExtract.path
        // The wrapper uses a local actor. Its graph is the only configured
        // routing input, and StatsD telemetry is disabled.
        config.removeValue(forKey: "statsd")
        config["mjolnir"] = mjolnir
        return try JSONSerialization.data(withJSONObject: config)
    }
    public init(configPath: String) throws {
        guard !configPath.utf8.contains(0) else { throw NativeRoutingFailure.configuration }
        let status = configPath.withCString { tm_router_create($0, &actor) }
        guard status == 0, actor != nil else { throw NativeRoutingFailure.engine }
    }
    public func route(rawRequest: String) throws -> Data {
        guard let actor, !rawRequest.utf8.contains(0), rawRequest.utf8.count <= 65536 else { throw NativeRoutingFailure.engine }
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = rawRequest.withCString { tm_router_route(actor, $0, &bytes, &length) }
        defer { tm_router_free(bytes) }
        guard status == 0, let bytes, length > 0, length <= 4 * 1024 * 1024 else { throw NativeRoutingFailure.response }
        return Data(bytes: bytes, count: length)
    }
    public func close() {
        if let actor { _ = tm_router_destroy(actor); self.actor = nil }
    }
    deinit { close() }
}
