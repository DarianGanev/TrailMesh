import Foundation

struct ProbeCheckpointStore {
    let url: URL

    static var applicationStore: ProbeCheckpointStore {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrailMeshTransportProbe", isDirectory: true)
        return ProbeCheckpointStore(url: directory.appendingPathComponent("session-v2.json"))
    }

    func load() throws -> ProbeSessionState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, (0...Int64(256 * 1024)).contains(size.int64Value) else { throw ProbeSessionError.invalidState }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(64 * 1024, 256 * 1024 + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= 256 * 1024 else { throw ProbeSessionError.invalidState }
        }
        let state = try JSONDecoder().decode(ProbeSessionState.self, from: data)
        guard state.isValid else { throw ProbeSessionError.invalidState }
        return state
    }

    func save(_ state: ProbeSessionState) throws {
        guard state.isValid else { throw ProbeSessionError.invalidState }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        guard data.count <= 256 * 1024 else { throw ProbeSessionError.invalidState }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
