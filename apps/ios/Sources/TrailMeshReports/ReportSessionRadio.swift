import Foundation
import Security

/// Ephemeral compatible-session metadata, never an author identity or location.
public struct ReportAdvertisement: Equatable, Sendable {
    public static let serviceID = "org.trailmesh.reports.v1"
    public static let fieldServiceID = "org.trailmesh.reports.field.v1"
    public let sessionID: String
    public static func parse(_ data: Data) -> ReportAdvertisement? {
        guard data.count == 37, let text = String(data: data, encoding: .ascii), text.hasPrefix("TMR1|") else { return nil }
        let id = String(text.dropFirst(5))
        guard id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), id != String(repeating: "0", count: 32) else { return nil }
        return ReportAdvertisement(sessionID: id)
    }
    public var encoded: Data { Data("TMR1|\(sessionID)".utf8) }
    public static func secureID() throws -> String { try secureNonce().map { String(format: "%02x", $0) }.joined() }
    static func secureNonce() throws -> Data {
        var data = Data(count: 16)
        guard data.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess,
              data != Data(repeating: 0, count: 16) else { throw ReportStoreError.random(errSecInternalError) }
        return data
    }
}
@MainActor
public protocol ReportSessionRadio: AnyObject {
    var delegate: (any ReportSessionRadioDelegate)? { get set }
    func start(advertisement: Data, epoch: UInt64)
    func stop()
    func connect(endpoint: String, advertisement: Data, epoch: UInt64)
    func disconnect(endpoint: String)
    /// Completion means SDK transmission only; it never means durable receipt.
    func send(_ bytes: Data, endpoint: String, ticket: UInt64) throws
}
@MainActor
public protocol ReportSessionRadioDelegate: AnyObject {
    func radioFound(endpoint: String, advertisement: Data, epoch: UInt64)
    func radioLost(endpoint: String, epoch: UInt64)
    func radioRequested(endpoint: String, advertisement: Data, epoch: UInt64) -> Bool
    func radioMayVerify(endpoint: String, epoch: UInt64) -> Bool
    func radioConnected(endpoint: String, epoch: UInt64)
    func radioDisconnected(endpoint: String, epoch: UInt64)
    func radioReceived(_ bytes: Data, endpoint: String, epoch: UInt64)
    func radioSent(ticket: UInt64, succeeded: Bool, endpoint: String, epoch: UInt64)
    func radioUnavailable(epoch: UInt64)
}
public enum ReportSessionPause: String, Sendable, Codable { case consentRequired, configurationRequired, foregroundRequired, radioUnavailable, storageFailure }
public enum ReportSessionState: Equatable, Sendable {
    case stopped, running, paused(ReportSessionPause)
    public var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .running: return "Sharing public reports while TrailMesh is open"
        case .paused(.consentRequired): return "Public sharing consent required"
        case .paused(.configurationRequired): return "Choose a usable area or route"
        case .paused(.foregroundRequired): return "Paused ? keep TrailMesh open to exchange reports"
        case .paused(.radioUnavailable): return "Interrupted ? check Bluetooth and local network permissions, then Resume"
        case .paused(.storageFailure): return "Interrupted ? storage or device clock needs attention"
        }
    }
    public var exportValue: String {
        switch self { case .stopped: return "stopped"; case .running: return "running"; case let .paused(reason): return "paused_" + reason.rawValue }
    }
}
public struct ReportSessionEvent: Codable, Sendable {
    public let code: String
    public let timestampMS: Int64
    public let peerSessionID: String?
    public let bundleID: String?
    enum CodingKeys: String, CodingKey { case code; case timestampMS = "timestamp_ms", peerSessionID = "peer_session_id", bundleID = "bundle_id" }
}
