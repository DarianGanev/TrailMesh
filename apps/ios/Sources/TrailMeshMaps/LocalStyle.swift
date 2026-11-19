import Foundation

public enum LocalStyle {
    public static func resolve(_ data: Data, root: URL, files: Set<String>) throws -> Data {
        guard data.count <= 1024 * 1024, var style = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              style["version"] as? Int == 8, style["imports"] == nil, style["terrain"] == nil,
              var sources = style["sources"] as? [String: [String: Any]], !sources.isEmpty else { throw MapFailure.corrupt }
        let allowed: Set<String> = ["version", "name", "metadata", "center", "zoom", "bearing", "pitch", "light", "transition", "glyphs", "sprite", "sources", "layers"]
        guard Set(style.keys).isSubset(of: allowed) else { throw MapFailure.corrupt }
        for (key, var source) in sources {
            let terrain = source["type"] as? String == "raster-dem"
            let path = terrain ? "terrain.pmtiles" : "map.pmtiles"
            guard ["vector", "raster-dem"].contains(source["type"] as? String ?? ""), files.contains(path), source["url"] as? String == "pmtiles://{PACK_ROOT}/\(path)",
                  source["tiles"] == nil, source["data"] == nil else { throw MapFailure.corrupt }
            if terrain { guard source["encoding"] as? String == "terrarium", source["tileSize"] as? Int == 256, source["minzoom"] as? Int == 10, source["maxzoom"] as? Int == 12 else { throw MapFailure.corrupt } }
            source["url"] = "pmtiles://" + root.appendingPathComponent(path).absoluteString
            sources[key] = source
        }
        style["sources"] = sources
        if let glyphs = style["glyphs"] {
            guard glyphs as? String == "{PACK_ROOT}/glyphs/{fontstack}/{range}.pbf", files.contains(where: { $0.hasPrefix("glyphs/") }) else { throw MapFailure.corrupt }
            style["glyphs"] = root.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/glyphs/{fontstack}/{range}.pbf"
        }
        if let layers = style["layers"] as? [[String: Any]] {
            for layer in layers where layer["type"] as? String == "symbol" {
                guard let layout = layer["layout"] as? [String: Any] else { continue }
                if layout["text-field"] == nil { continue }
                guard style["glyphs"] != nil, let fonts = layout["text-font"] as? [String], !fonts.isEmpty,
                      fonts.allSatisfy({ RegionManifest.safePath($0) && !$0.contains("/") && !$0.contains(",") }) else { throw MapFailure.corrupt }
                let stack = fonts.joined(separator: ",")
                // Frozen Rila label coverage: Latin, Latin Extended and Cyrillic.
                for range in ["0-255", "256-511", "1024-1279"] {
                    guard files.contains("glyphs/\(stack)/\(range).pbf") else { throw MapFailure.corrupt }
                }
            }
        }
        if let sprite = style["sprite"] {
            guard sprite as? String == "{PACK_ROOT}/sprite", ["sprite.json","sprite.png","sprite@2x.json","sprite@2x.png"].allSatisfy(files.contains) else { throw MapFailure.corrupt }
            style["sprite"] = root.appendingPathComponent("sprite").absoluteString
        }
        // Layers cannot introduce source-specific network resources.
        func check(_ value: Any) throws {
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    if ["url","tiles","data","imports","terrain"].contains(key) { throw MapFailure.corrupt }
                    try check(child)
                }
            } else if let array = value as? [Any] { for child in array { try check(child) } }
        }
        if let layers = style["layers"] { try check(layers) }
        return try JSONSerialization.data(withJSONObject: style, options: [.sortedKeys])
    }
}
