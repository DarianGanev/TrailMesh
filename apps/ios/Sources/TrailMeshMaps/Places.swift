import Foundation

public struct Place: Codable, Sendable {
    public let id: String, name: String, aliases: [String], kind: String
    public let latE7: Int64, lonE7: Int64
}
public struct PlaceIndex: Sendable {
    public let places: [Place]
    private struct Document: Decodable { let format: Int; let places: [Place] }
    public init(data: Data) throws {
        guard data.count <= 8 * 1024 * 1024 else { throw MapFailure.corrupt }
        var reader = try StrictMapJSONParser(data)
        _ = try reader.parse()
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["format", "places"],
              let entries = object["places"] as? [[String: Any]], entries.allSatisfy({ Set($0.keys) == ["id", "name", "aliases", "kind", "latE7", "lonE7"] }) else { throw MapFailure.corrupt }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.format == 1, document.places.count <= 25000 else { throw MapFailure.corrupt }
        var ids = Set<String>()
        for p in document.places {
            guard RegionManifest.text(p.id, maximum: 160), RegionManifest.matches(p.id, "^(node|way|relation)/[1-9][0-9]*$"), ids.insert(p.id).inserted, RegionManifest.text(p.name, maximum: 120), p.aliases.count <= 8,
                  p.aliases.allSatisfy({ RegionManifest.text($0, maximum: 120) }), ["hut","peak","shelter","water","trailhead","place"].contains(p.kind),
                  MapPoint(latE7: p.latE7, lonE7: p.lonE7).valid else { throw MapFailure.corrupt }
        }
        places = document.places.sorted { Self.normalized($0.name) == Self.normalized($1.name) ? $0.id < $1.id : Self.normalized($0.name) < Self.normalized($1.name) }
    }
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func words(_ text: String) -> [Substring] {
        normalized(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    }
    public func search(_ query: String, limit: Int = 50) -> [Place] {
        let tokens = Self.words(query)
        guard !tokens.isEmpty, limit > 0 else { return [] }
        return Array(places.filter { place in
            ([place.name] + place.aliases).contains { name in
                let words = Self.words(name)
                return tokens.allSatisfy { token in words.contains { $0.hasPrefix(token) } }
            }
        }.prefix(min(limit, 50)))
    }
}
