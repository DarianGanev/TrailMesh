import Foundation

enum ProbeSessionError: Error {
    case invalidState, unknownPeer, journalFull, transmissionLimit, invalidAttempt, invalidFinish
}

struct ProbePeerProgress: Codable, Equatable {
    let sessionID: String
    var nextAttempt = 0
    var transmissions = 0
    var successful = 0
    var failed = 0
    var receivedAttempts: [Int] = []
    var duplicates = 0
    var remoteSuccessful: Int?
    var remoteFailed: Int?
    var localFinishAcknowledged = false
    var remoteFinishAcknowledgementDelivered = false
    var completedAt: Date?

    var outgoingComplete: Bool { nextAttempt == 20 }
    var remoteFinished: Bool { remoteSuccessful != nil && remoteFailed != nil }
    var complete: Bool {
        outgoingComplete && remoteFinished && localFinishAcknowledged && remoteFinishAcknowledgementDelivered
    }
    var needsReciprocalProgressDeadline: Bool { outgoingComplete && localFinishAcknowledged && !complete }
}

struct ProbeLogEntry: Codable {
    let event: String
    let observedAt: String
    let fields: [String: String]

    var exported: [String: Any] {
        var result: [String: Any] = ["event": event, "observed_at": observedAt]
        for (key, value) in fields {
            if ["attempt_index", "payload_size_bytes", "retry", "transmission"].contains(key), let number = Int(value) {
                result[key] = number
            } else if key == "success" {
                result[key] = value == "true"
            } else { result[key] = value }
        }
        return result
    }
}

/// Durable intention and per-peer progress. Endpoint IDs and authentication tokens are never saved.
struct ProbeSessionState: Codable {
    let version: Int
    let sessionID: String
    let payloadSize: Int
    var intendedActive: Bool
    var peers: [ProbePeerProgress]
    var records: [ProbeLogEntry]

    init(sessionID: String, payloadSize: Int) {
        version = 2
        self.sessionID = sessionID
        self.payloadSize = payloadSize
        intendedActive = true
        peers = []
        records = []
    }

    static func validSessionID(_ value: String) -> Bool {
        value.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    var isValid: Bool {
        guard version == 2, Self.validSessionID(sessionID), [256, 2048, 8192].contains(payloadSize),
              peers.count <= 8, records.count <= 512, Set(peers.map(\.sessionID)).count == peers.count else { return false }
        guard records.allSatisfy({ entry in
            entry.event.count <= 64 && entry.observedAt.count <= 40 && entry.fields.count <= 12
            && entry.fields.allSatisfy { $0.key.count <= 64 && $0.value.count <= 256 }
        }) else { return false }
        return peers.allSatisfy {
            Self.validSessionID($0.sessionID) && $0.sessionID != sessionID && (0...20).contains($0.nextAttempt)
            && (0...3).contains($0.transmissions) && (0...20).contains($0.successful) && (0...20).contains($0.failed)
            && $0.successful + $0.failed == $0.nextAttempt && (0...100_000).contains($0.duplicates)
            && Set($0.receivedAttempts).count == $0.receivedAttempts.count
            && $0.receivedAttempts.allSatisfy { (0..<20).contains($0) }
            && (($0.remoteSuccessful == nil && $0.remoteFailed == nil)
                || ((0...20).contains($0.remoteSuccessful ?? -1) && (0...20).contains($0.remoteFailed ?? -1)
                    && ($0.remoteSuccessful ?? -1) + ($0.remoteFailed ?? -1) == 20))
            && (!$0.localFinishAcknowledged || $0.outgoingComplete)
            && (!$0.remoteFinishAcknowledgementDelivered || $0.remoteFinished)
            && ($0.completedAt == nil || ($0.outgoingComplete && $0.remoteFinished
                && $0.completedAt!.timeIntervalSince1970.isFinite))
        }
    }

    func peer(_ id: String) -> ProbePeerProgress? { peers.first { $0.sessionID == id } }

    var shouldPauseForFullJournal: Bool {
        peers.count == 8 && peers.allSatisfy { $0.complete }
    }

    mutating func prepareLink(to id: String) throws {
        guard let index = peers.firstIndex(where: { $0.sessionID == id }) else { throw ProbeSessionError.unknownPeer }
        // FINISH acknowledgement delivery belongs to the current link; durable DATA progress does not reset.
        peers[index].localFinishAcknowledged = false
        peers[index].remoteFinishAcknowledgementDelivered = false
    }

    mutating func bindPeer(_ id: String) throws {
        guard Self.validSessionID(id), id != sessionID else { throw ProbeSessionError.invalidState }
        if peer(id) != nil { return }
        guard peers.count < 8 else { throw ProbeSessionError.journalFull }
        peers.append(ProbePeerProgress(sessionID: id))
    }

    @discardableResult
    mutating func beginTransmission(to id: String) throws -> Int {
        guard let index = peers.firstIndex(where: { $0.sessionID == id }) else { throw ProbeSessionError.unknownPeer }
        guard peers[index].nextAttempt < 20 else { throw ProbeSessionError.invalidAttempt }
        guard peers[index].transmissions < 3 else { throw ProbeSessionError.transmissionLimit }
        peers[index].transmissions += 1
        return peers[index].nextAttempt
    }

    @discardableResult
    mutating func finishAttempt(to id: String, attempt: Int, success: Bool) throws -> Bool {
        guard let index = peers.firstIndex(where: { $0.sessionID == id }) else { throw ProbeSessionError.unknownPeer }
        guard peers[index].nextAttempt == attempt, peers[index].transmissions > 0, attempt < 20 else { return false }
        if success { peers[index].successful += 1 } else { peers[index].failed += 1 }
        peers[index].nextAttempt += 1
        peers[index].transmissions = 0
        return true
    }

    @discardableResult
    mutating func recordReceived(from id: String, attempt: Int) throws -> Bool {
        guard (0..<20).contains(attempt) else { throw ProbeSessionError.invalidAttempt }
        guard let index = peers.firstIndex(where: { $0.sessionID == id }) else { throw ProbeSessionError.unknownPeer }
        if peers[index].receivedAttempts.contains(attempt) {
            peers[index].duplicates = min(100_000, peers[index].duplicates + 1)
            return false
        }
        peers[index].receivedAttempts.append(attempt)
        peers[index].receivedAttempts.sort()
        return true
    }

    mutating func recordRemoteFinish(from id: String, successful: Int, failed: Int) throws {
        guard let index = peers.firstIndex(where: { $0.sessionID == id }) else { throw ProbeSessionError.unknownPeer }
        guard (0...20).contains(successful), (0...20).contains(failed), successful + failed == 20 else { throw ProbeSessionError.invalidFinish }
        if let previous = peers[index].remoteSuccessful,
           previous != successful || peers[index].remoteFailed != failed { throw ProbeSessionError.invalidFinish }
        peers[index].remoteSuccessful = successful
        peers[index].remoteFailed = failed
        peers[index].remoteFinishAcknowledgementDelivered = false
    }

    mutating func recordLocalFinishAcknowledgement(from id: String, successful: Int, failed: Int) throws {
        guard let index = peers.firstIndex(where: { $0.sessionID == id }) else { throw ProbeSessionError.unknownPeer }
        guard peers[index].outgoingComplete, peers[index].successful == successful,
              peers[index].failed == failed else { throw ProbeSessionError.invalidFinish }
        peers[index].localFinishAcknowledged = true
        if peers[index].complete, peers[index].completedAt == nil { peers[index].completedAt = Date() }
    }

    mutating func recordRemoteFinishAcknowledgementDelivered(to id: String) throws {
        guard let index = peers.firstIndex(where: { $0.sessionID == id }), peers[index].remoteFinished else {
            throw ProbeSessionError.invalidFinish
        }
        peers[index].remoteFinishAcknowledgementDelivered = true
        if peers[index].complete, peers[index].completedAt == nil { peers[index].completedAt = Date() }
    }
}

enum ProbeRecoveryPolicy {
    static let reciprocalProgressTimeout: TimeInterval = 60
    static func shouldRenewReciprocalDeadline(uniqueReceived: Bool, peer: ProbePeerProgress) -> Bool {
        uniqueReceived && peer.needsReciprocalProgressDeadline
    }
    static func delay(forRetry retry: Int) -> TimeInterval { min(30, pow(2, Double(max(0, min(5, retry - 1))))) }
    static func canRetry(_ retry: Int) -> Bool { (1...5).contains(retry) }
    static func shouldResume(intendedActive: Bool, foreground: Bool, transportRunning: Bool) -> Bool {
        intendedActive && foreground && !transportRunning
    }
}

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
