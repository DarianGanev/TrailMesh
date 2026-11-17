import Foundation

public struct InstalledRegion: Sendable {
    public let manifest: RegionManifest
    public let root: URL
}

/// The transport writes at most expectedBytes and validates any range response.
/// Injection keeps the installer testable without network or native SDKs.
public protocol PackTransport: Sendable {
    func fetch(url: URL, destination: URL, expectedBytes: Int64, cancellation: InstallCancellation) async throws
}

final class PackRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirects = 0
    static func allowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock(); redirects += 1; let withinLimit = redirects <= 5; lock.unlock()
        completionHandler(withinLimit && Self.allowed(request.url) ? request : nil)
    }
}

public struct HTTPSPackTransport: PackTransport {
    public init() {}
    public func fetch(url: URL, destination: URL, expectedBytes: Int64, cancellation: InstallCancellation) async throws {
        let fm = FileManager.default
        let validatorURL = destination.appendingPathExtension("etag")
        if (try? validatorURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw MapFailure.corrupt }
        let savedValidator = try? String(contentsOf: validatorURL, encoding: .utf8)
        let strongValidator = savedValidator.map { $0.hasPrefix("\"") && $0.hasSuffix("\"") && !$0.contains("\n") && $0.utf8.count <= 512 } ?? false
        let currentSize = ((try? fm.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let offset = strongValidator ? currentSize : 0
        if offset == 0 { try Data().write(to: destination) }
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(savedValidator, forHTTPHeaderField: "If-Range")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: PackRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https", http.url?.user == nil, http.url?.password == nil,
              [200, 206].contains(http.statusCode), http.value(forHTTPHeaderField: "Content-Encoding").map({ $0 == "identity" }) ?? true else { throw MapFailure.corrupt }
        var written: Int64 = 0
        if http.statusCode == 206 {
            guard offset > 0, http.value(forHTTPHeaderField: "ETag") == savedValidator,
                  http.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(expectedBytes - 1)/\(expectedBytes)" else { throw MapFailure.corrupt }
            written = offset
        } else {
            try Data().write(to: destination)
        }
        if let etag = http.value(forHTTPHeaderField: "ETag"), etag.hasPrefix("\""), etag.hasSuffix("\""), etag.utf8.count <= 512, !etag.contains("\n") {
            try Data(etag.utf8).write(to: validatorURL, options: .atomic)
        } else { try? fm.removeItem(at: validatorURL) }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(written))
        var buffer = Data(); buffer.reserveCapacity(65536)
        for try await byte in stream {
            try cancellation.check()
            written += 1
            guard written <= expectedBytes else { throw MapFailure.corrupt }
            buffer.append(byte)
            if buffer.count == 65536 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        try handle.write(contentsOf: buffer)
        try handle.synchronize()
        guard written == expectedBytes else { throw MapFailure.corrupt }
        try? fm.removeItem(at: validatorURL)
    }
}

public actor RegionStore {
    public let root: URL
    public nonisolated let leases: PackLeases
    public init(root: URL) {
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        self.root = canonical
        self.leases = PackRootRegistry.shared.leases(for: canonical)
    }
    private func safeDirectory(_ url: URL) throws {
        let fm = FileManager.default
        let base = root.path
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(base + "/") || resolved == base else { throw MapFailure.corrupt }
        var part = url.standardizedFileURL
        while true {
            if (try? fm.attributesOfItem(atPath: part.path)[.type]) as? FileAttributeType == .typeSymbolicLink { throw MapFailure.corrupt }
            if part.resolvingSymlinksInPath().path == base { return }
            guard part.path != "/" else { throw MapFailure.corrupt }
            part.deleteLastPathComponent()
        }
    }
    public func install(manifestData: Data, expectedSHA256: String, releaseDirectory: URL, transport: any PackTransport = HTTPSPackTransport(), cancellation: InstallCancellation = InstallCancellation()) async throws -> InstalledRegion {
        let manifest = try RegionManifest.parse(manifestData, expectedSHA256: expectedSHA256)
        guard releaseDirectory.scheme == "https", releaseDirectory.host != nil, releaseDirectory.user == nil,
              releaseDirectory.password == nil, releaseDirectory.query == nil, releaseDirectory.fragment == nil else { throw MapFailure.corrupt }
        try leases.beginInstallation(manifest.key)
        defer { leases.endInstallation(manifest.key) }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let final = root.appendingPathComponent(manifest.key)
        let staging = root.appendingPathComponent(".staging/\(manifest.id)-\(manifest.revision)-\(expectedSHA256)")
        try safeDirectory(staging); try safeDirectory(final)
        if fm.fileExists(atPath: final.path) { return try verify(root: final, expectedSHA256: expectedSHA256) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        var remaining: Int64 = 0
        for f in manifest.files {
            let target = staging.appendingPathComponent(f.path)
            try safeDirectory(target)
            let size = ((try? fm.attributesOfItem(atPath: target.path)[.size]) as? NSNumber)?.int64Value ?? 0
            if size == f.bytes, (try? RegionManifest.hashFile(target)) != f.sha256 { remaining += f.bytes }
            else { remaining += max(0, f.bytes - min(size, f.bytes)) }
        }
        let space = try fm.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber
        guard let space, space.int64Value >= remaining + 8 * 1024 * 1024 else { throw MapFailure.space }
        for f in manifest.files {
            try cancellation.check()
            let target = staging.appendingPathComponent(f.path)
            try safeDirectory(target)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = ((try? fm.attributesOfItem(atPath: target.path)[.size]) as? NSNumber)?.int64Value ?? 0
            if size == f.bytes, try RegionManifest.hashFile(target) == f.sha256 { continue }
            if size >= f.bytes { try fm.removeItem(at: target) }
            if !fm.fileExists(atPath: target.path) { fm.createFile(atPath: target.path, contents: nil) }
            try await transport.fetch(url: releaseDirectory.appendingPathComponent(f.asset), destination: target, expectedBytes: f.bytes, cancellation: cancellation)
            guard try RegionManifest.hashFile(target) == f.sha256 else { try? fm.removeItem(at: target); throw MapFailure.corrupt }
            try? fm.removeItem(at: target.appendingPathExtension("etag"))
        }
        _ = try verify(root: staging, expectedSHA256: expectedSHA256)
        try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cancellation.publish { try fm.moveItem(at: staging, to: final) }
        return InstalledRegion(manifest: manifest, root: final)
    }
    public func verify(root directory: URL, expectedSHA256: String) throws -> InstalledRegion {
        try safeDirectory(directory)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try safeDirectory(manifestURL)
        let size = try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.size] as? NSNumber
        guard let size, size.intValue <= 262144 else { throw MapFailure.corrupt }
        let manifest = try RegionManifest.parse(Data(contentsOf: manifestURL), expectedSHA256: expectedSHA256)
        for f in manifest.files {
            let file = directory.appendingPathComponent(f.path)
            try safeDirectory(file)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.int64Value == f.bytes,
                  try RegionManifest.hashFile(file) == f.sha256 else { throw MapFailure.corrupt }
            if f.path.hasSuffix(".pmtiles") { try PMTilesMetadata.validate(file) }
        }
        let paths = Set(manifest.files.map(\.path))
        _ = try LocalStyle.resolve(Data(contentsOf: directory.appendingPathComponent("style.json")), root: directory, files: paths)
        let index = try PlaceIndex(data: Data(contentsOf: directory.appendingPathComponent("places.json")))
        guard index.places.allSatisfy({ manifest.contains(MapPoint(latE7: $0.latE7, lonE7: $0.lonE7)) }) else { throw MapFailure.corrupt }
        return InstalledRegion(manifest: manifest, root: directory)
    }
    public func remove(_ region: InstalledRegion) throws {
        try safeDirectory(region.root)
        try leases.withRemoval(region.manifest.key) { try FileManager.default.removeItem(at: region.root) }
    }
    public func lease(_ region: InstalledRegion) throws -> PackLease {
        try safeDirectory(region.root)
        return try leases.acquire(region.manifest.key) {
            guard FileManager.default.fileExists(atPath: region.root.path) else { throw MapFailure.unavailable }
        }
    }
    /// Reopen a pinned immutable revision without consulting the network.
    public func openInstalled(id: String, revision: String, expectedSHA256: String) throws -> InstalledRegion {
        guard id.utf8.count <= 64, revision.utf8.count <= 64,
              RegionManifest.matches(id, "^[a-z0-9]+(?:-[a-z0-9]+)*$"),
              RegionManifest.matches(revision, "^[a-z0-9]+(?:-[a-z0-9]+)*$") else { throw MapFailure.corrupt }
        let directory = root.appendingPathComponent("\(id)/\(revision)")
        try safeDirectory(directory)
        guard FileManager.default.fileExists(atPath: directory.path) else { throw MapFailure.unavailable }
        return try verify(root: directory, expectedSHA256: expectedSHA256)
    }
    /// Catalog supplies trusted manifest pins; unpinned directories are never
    /// promoted after restart, including abandoned staging directories.
    public func discover(catalog: [String: String]) -> [InstalledRegion] {
        catalog.sorted(by: { $0.key < $1.key }).compactMap { key, hash in
            guard key.split(separator: "/").count == 2, RegionManifest.safePath(key) else { return nil }
            return try? verify(root: root.appendingPathComponent(key), expectedSHA256: hash)
        }
    }
}
