import CryptoKit
import Foundation

struct ReportAdmissionResult {
    let outcome: String
    let bundleID: String?
    let canonicalCore: Data?
    let canonicalEnvelope: Data?
}

enum ReportAdmission {
    private static func reject(_ outcome: String = "invalid") -> ReportAdmissionResult {
        ReportAdmissionResult(outcome: outcome, bundleID: nil, canonicalCore: nil, canonicalEnvelope: nil)
    }
    static func binary(_ value: ReportJSON?, count: Int) -> Data? {
        guard let text = value?.string, !text.isEmpty,
              text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let bytes = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)), bytes.count == count else { return nil }
        let canonical = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return canonical == text ? bytes : nil
    }
    private static func identifier(_ value: ReportJSON?) -> String? {
        guard let text = value?.string, text.utf8.count == 64,
              text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return text
    }
    static func validate(_ wire: Data, now: Int64) -> ReportAdmissionResult {
        guard (0...9_007_199_254_740_991).contains(now) else { return reject() }
        do {
            var parser = try StrictReportJSONParser(wire)
            let envelope = try parser.parse()
            guard envelope.hasFields(["core", "signature", "bundle_id"]),
                  let core = envelope["core"],
                  core.hasFields(["protocol", "version", "kind", "author_key", "nonce", "created_at_ms", "expires_at_ms", "max_hops", "body"]),
                  core["protocol"]?.string == "trailmesh", let version = core["version"]?.integer,
                  let kind = core["kind"]?.string else { return reject() }
            guard version == 1, kind == "report" else { return reject("unsupported") }
            guard let body = core["body"], body.hasFields(["event_id", "category", "status", "observed_at_ms", "lat_e7", "lon_e7", "accuracy_m", "note", "supersedes"]),
                  let author = binary(core["author_key"], count: 32),
                  binary(core["nonce"], count: 16) != nil,
                  binary(body["event_id"], count: 16) != nil,
                  let signature = binary(envelope["signature"], count: 64),
                  let id = identifier(envelope["bundle_id"]) else { return reject() }
            if case .null? = body["supersedes"] {} else if identifier(body["supersedes"]) == nil { return reject() }
            let statuses: [String: Set<String>] = [
                "water": ["flowing", "low", "dry", "unknown"],
                "obstruction": ["clear", "partial", "blocked", "unknown"],
                "trail": ["good", "muddy", "icy", "damaged", "blocked", "unknown"],
                "weather": ["clear", "rain", "snow", "storm", "fog", "unknown"],
                "campsite": ["available", "occupied", "closed", "unknown"],
                "hut": ["open", "closed", "unknown"],
                "crowding": ["quiet", "moderate", "busy", "unknown"],
                "note": ["observed", "unknown"]
            ]
            guard let category = body["category"]?.string, let status = body["status"]?.string,
                  statuses[category]?.contains(status) == true,
                  let note = body["note"]?.string, note.unicodeScalars.count <= 500, note.utf8.count <= 2048,
                  let created = core["created_at_ms"]?.integer, let expires = core["expires_at_ms"]?.integer,
                  let hops = core["max_hops"]?.integer, let observed = body["observed_at_ms"]?.integer,
                  let lat = body["lat_e7"]?.integer, let lon = body["lon_e7"]?.integer,
                  let accuracy = body["accuracy_m"]?.integer,
                  observed >= 0, observed <= created, created < expires, expires - created <= 259_200_000,
                  (-900_000_000...900_000_000).contains(lat), (-1_800_000_000...1_800_000_000).contains(lon),
                  accuracy >= 0, (0...12).contains(hops) else { return reject() }
            let canonical = Data(core.canonical().utf8)
            var idMessage = Data("TrailMesh/id/v1\n".utf8)
            idMessage.append(canonical)
            let digest = SHA256.hash(data: idMessage).map { String(format: "%02x", $0) }.joined()
            guard digest == id else { return reject() }
            var signedMessage = Data("TrailMesh/core/v1\n".utf8)
            signedMessage.append(canonical)
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: author)
            guard key.isValidSignature(signature, for: signedMessage) else { return reject() }
            guard created <= now + 300_000 else { return reject() }
            guard now < expires else { return reject("expired") }
            return ReportAdmissionResult(outcome: "accepted", bundleID: id, canonicalCore: canonical,
                                         canonicalEnvelope: Data(envelope.canonical().utf8))
        } catch {
            return reject()
        }
    }
}
