import Foundation

enum ProbePlatform: String, Codable {
    case android = "A"
    case ios = "I"
}

/// Ephemeral test metadata. Compatibility does not authenticate the peer.
struct ProbePeerContext: Equatable, Codable {
    let platform: ProbePlatform
    let sessionID: String
    let payloadSize: Int

    static let supportedPayloadSizes: Set<Int> = [256, 2048, 8192]

    var encoded: String { isValid ? "TM2|\(platform.rawValue)|\(sessionID)|\(payloadSize)" : "" }

    func isCompatible(with peer: ProbePeerContext) -> Bool {
        isValid && peer.isValid && sessionID != peer.sessionID && payloadSize == peer.payloadSize &&
            !(platform == .ios && peer.platform == .ios)
    }

    func canInitiate(to peer: ProbePeerContext) -> Bool {
        guard isCompatible(with: peer) else { return false }
        if platform == .ios { return true }
        if peer.platform == .ios { return false }
        return sessionID < peer.sessionID
    }

    static func parse(_ context: Data) -> ProbePeerContext? {
        guard (42...43).contains(context.count), context.allSatisfy({ (32...126).contains($0) }),
              let text = String(data: context, encoding: .ascii) else { return nil }
        let fields = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4, fields[0] == "TM2", let platform = ProbePlatform(rawValue: fields[1]),
              isValidSessionID(fields[2]) else { return nil }
        let payloadSize: Int
        switch fields[3] {
        case "256": payloadSize = 256
        case "2048": payloadSize = 2048
        case "8192": payloadSize = 8192
        default: return nil
        }
        return ProbePeerContext(platform: platform, sessionID: fields[2], payloadSize: payloadSize)
    }

    static func isValidSessionID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private var isValid: Bool { Self.isValidSessionID(sessionID) && Self.supportedPayloadSizes.contains(payloadSize) }
}
