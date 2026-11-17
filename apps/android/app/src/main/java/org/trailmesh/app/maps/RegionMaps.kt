package org.trailmesh.app.maps

import com.google.gson.GsonBuilder
import com.google.gson.JsonParser
import com.google.gson.JsonSerializer
import com.google.gson.Strictness
import com.google.gson.stream.JsonReader
import com.google.gson.stream.JsonToken
import java.io.File
import java.io.StringReader
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.text.Normalizer
import java.time.LocalDate
import java.util.Locale

/** Errors are suitable for a local UI. They contain neither route geometry nor server bodies. */
enum class MapError {
    UNAVAILABLE,
    CORRUPT,
    SPACE,
    CANCELLED,
    OUTSIDE_COVERAGE,
    NO_ROUTE,
    INVALID_ENGINE,
    BUSY,
    RELEVANCE_TOO_COMPLEX,
}

class MapFailure(val reason: MapError) : Exception(reason.name)

internal fun need(ok: Boolean, reason: MapError = MapError.CORRUPT) {
    if (!ok) throw MapFailure(reason)
}

internal fun sha256(bytes: ByteArray) =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

internal fun sha256(file: File): String {
    val hash = MessageDigest.getInstance("SHA-256")
    file.inputStream().use { input ->
        val buffer = ByteArray(65536)
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            hash.update(buffer, 0, n)
        }
    }
    return hash.digest().joinToString("") { "%02x".format(it) }
}

/** Strict, duplicate-rejecting JSON for bounded pack/engine documents, independent of Android. */
internal data class MapNumber(val literal: String)

internal object MapJson {
    fun parse(bytes: ByteArray, limit: Int): Any? =
        try {
            need(bytes.size <= limit)
            val text =
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes))
                    .toString()
            need(!text.startsWith('\uFEFF'))
            JsonReader(StringReader(text)).use { r ->
                r.strictness = Strictness.STRICT
                val v = read(r, 0)
                need(r.peek() == JsonToken.END_DOCUMENT)
                v
            }
        } catch (e: MapFailure) {
            throw e
        } catch (_: Exception) {
            throw MapFailure(MapError.CORRUPT)
        }

    private fun read(r: JsonReader, d: Int): Any? {
        need(d <= 32)
        return when (r.peek()) {
            JsonToken.BEGIN_OBJECT -> {
                val m = linkedMapOf<String, Any?>()
                r.beginObject()
                while (r.hasNext()) {
                    val key = r.nextName().also { unicode(it) }
                    need(!m.containsKey(key))
                    m[key] = read(r, d + 1)
                }
                r.endObject()
                m
            }
            JsonToken.BEGIN_ARRAY -> {
                val a = mutableListOf<Any?>()
                r.beginArray()
                while (r.hasNext()) a.add(read(r, d + 1))
                r.endArray()
                a
            }
            JsonToken.STRING -> r.nextString().also { unicode(it) }
            JsonToken.NUMBER -> MapNumber(r.nextString())
            JsonToken.BOOLEAN -> r.nextBoolean()
            JsonToken.NULL -> {
                r.nextNull()
                null
            }
            else -> throw MapFailure(MapError.CORRUPT)
        }
    }

    private fun unicode(text: String) {
        var i = 0
        while (i < text.length) {
            val c = text[i++]
            if (c.isHighSurrogate()) need(i < text.length && text[i++].isLowSurrogate())
            else need(!c.isLowSurrogate())
        }
    }

    fun encode(v: Any?): String =
        GsonBuilder()
            .registerTypeAdapter(
                MapNumber::class.java,
                JsonSerializer<MapNumber> { number, _, _ ->
                    JsonParser.parseString(number.literal)
                },
            )
            .create()
            .toJson(v)
}

@Suppress("UNCHECKED_CAST")
internal fun Any?.obj() = this as? Map<String, Any?> ?: throw MapFailure(MapError.CORRUPT)

internal fun Any?.arr() = this as? List<*> ?: throw MapFailure(MapError.CORRUPT)

internal fun Any?.str() = this as? String ?: throw MapFailure(MapError.CORRUPT)

internal fun Any?.integer(): Long {
    val literal = (this as? MapNumber)?.literal ?: throw MapFailure(MapError.CORRUPT)
    need(literal.matches(Regex("-?(0|[1-9][0-9]*)")))
    return literal.toLongOrNull() ?: throw MapFailure(MapError.CORRUPT)
}

internal fun Any?.decimal(): Double {
    val v = (this as? MapNumber)?.literal?.toDoubleOrNull() ?: throw MapFailure(MapError.CORRUPT)
    need(v.isFinite())
    return v
}

internal fun Map<String, Any?>.fields(vararg keys: String) {
    need(this.keys == keys.toSet())
}

internal fun String.bounded(max: Int) {
    need(isNotBlank() && codePointCount(0, length) <= max && none { it.code < 32 })
}

internal fun safePath(path: String): Boolean =
    path.length in 1..160 &&
        path.matches(Regex("[A-Za-z0-9_ ./,@+\\-]+")) &&
        path.split('/').all { it.isNotEmpty() && it != "." && it != ".." }

data class MapPoint(val latE7: Long, val lonE7: Long) {
    fun valid() = latE7 in -900000000..900000000 && lonE7 in -1800000000..1800000000
}

data class BoundsE7(val west: Long, val south: Long, val east: Long, val north: Long) {
    fun contains(p: MapPoint) = p.valid() && p.lonE7 in west..east && p.latE7 in south..north
}

data class RegionFile(val path: String, val asset: String, val bytes: Long, val sha256: String)

data class RegionManifest(
    val id: String,
    val revision: String,
    val bounds: BoundsE7,
    val files: List<RegionFile>,
    val attribution: String,
    val name: String,
    val dataDate: String,
) {
    companion object {
        fun parse(bytes: ByteArray, hash: String): RegionManifest {
            need(hash.matches(Regex("[0-9a-f]{64}")) && sha256(bytes) == hash)
            val o = MapJson.parse(bytes, 262144).obj()
            o.fields(
                "format",
                "id",
                "revision",
                "name",
                "dataDate",
                "boundsE7",
                "minZoom",
                "maxZoom",
                "engine",
                "attribution",
                "files",
            )
            need(
                o["format"].integer() == 1L &&
                    o["minZoom"].integer() == 0L &&
                    o["maxZoom"].integer() == 14L
            )
            need(o["engine"].str() == "valhalla-3.9.2", MapError.INVALID_ENGINE)
            val id = o["id"].str()
            val rev = o["revision"].str()
            need(
                listOf(id, rev).all {
                    it.matches(Regex("[a-z0-9]+(?:-[a-z0-9]+)*")) && it.length <= 64
                }
            )
            val name = o["name"].str().also { it.bounded(120) }
            val attribution = o["attribution"].str().also { it.bounded(1000) }
            val date = o["dataDate"].str()
            need(date.matches(Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")))
            try {
                LocalDate.parse(date)
            } catch (_: Exception) {
                throw MapFailure(MapError.CORRUPT)
            }
            val b = o["boundsE7"].arr()
            need(b.size == 4)
            val bounds = BoundsE7(b[0].integer(), b[1].integer(), b[2].integer(), b[3].integer())
            need(
                bounds.west >= -1800000000 &&
                    bounds.east <= 1800000000 &&
                    bounds.south >= -900000000 &&
                    bounds.north <= 900000000 &&
                    bounds.west < bounds.east &&
                    bounds.south < bounds.north
            )
            val files =
                o["files"].arr().map { v ->
                    val f = v.obj()
                    f.fields("path", "asset", "bytes", "sha256")
                    RegionFile(
                        f["path"].str(),
                        f["asset"].str(),
                        f["bytes"].integer(),
                        f["sha256"].str(),
                    )
                }
            need(files.size in 1..256 && files.sumOf { it.bytes } in 1..2147483647L)
            need(
                files.all {
                    safePath(it.path) &&
                        safePath(it.asset) &&
                        !it.asset.contains('/') &&
                        it.bytes in 1..2147483647L &&
                        it.sha256.matches(Regex("[0-9a-f]{64}"))
                }
            )
            need(
                files.map { it.path.lowercase(Locale.ROOT) }.toSet().size == files.size &&
                    files.map { it.asset.lowercase(Locale.ROOT) }.toSet().size == files.size
            )
            // A file may not be another file's parent (including on case-insensitive filesystems).
            val paths = files.map { it.path.lowercase(Locale.ROOT) }
            need(paths.none { p -> paths.any { it != p && it.startsWith("$p/") } })
            need(
                files
                    .map { it.path }
                    .containsAll(
                        listOf(
                            "map.pmtiles",
                            "routing.tar",
                            "places.json",
                            "style.json",
                            "licenses/OSM.txt",
                        )
                    )
            )
            need(
                files.none {
                    it.path.substringBefore('/').lowercase(Locale.ROOT) in
                        setOf("manifest.json", "manifest.sha256", "runtime-style.json", ".partials")
                }
            )
            return RegionManifest(id, rev, bounds, files, attribution, name, date)
        }
    }
}

object ClosedStyle {
    fun resolve(bytes: ByteArray, m: RegionManifest, root: File): String {
        val style = MapJson.parse(bytes, 8 * 1024 * 1024).obj()
        need(
            style["version"].integer() == 8L &&
                !style.containsKey("imports") &&
                !style.containsKey("terrain")
        )
        val paths = m.files.map { it.path }.toSet()
        val sources = style["sources"].obj()
        need(sources.isNotEmpty())
        for ((_, v) in sources) {
            val s = v.obj()
            val type = s["type"].str()
            need(type == "vector" || type == "raster-dem")
            need(!s.containsKey("tiles") && !s.containsKey("data") && !s.containsKey("coordinates"))
            val file = if (type == "vector") "map.pmtiles" else "terrain.pmtiles"
            need(s["url"].str() == "pmtiles://{PACK_ROOT}/$file" && file in paths)
            if (type == "raster-dem")
                need(s["encoding"].str() == "terrarium" && s["tileSize"].integer() == 256L)
        }
        style["glyphs"]?.let {
            need(it.str() == "{PACK_ROOT}/glyphs/{fontstack}/{range}.pbf")
            need(paths.any { p -> p.startsWith("glyphs/") && p.endsWith(".pbf") })
        }
        style["sprite"]?.let {
            need(it.str() == "{PACK_ROOT}/sprite")
            need(
                paths.containsAll(
                    listOf("sprite.json", "sprite.png", "sprite@2x.json", "sprite@2x.png")
                )
            )
        }
        need(style["layers"].arr().size <= 512)
        // No hidden fetch paths in metadata, layers or unsupported root/source properties.
        fun inspect(value: Any?) {
            when (value) {
                is Map<*, *> ->
                    value.forEach { (k, v) ->
                        need(k !in setOf("tiles", "imports", "image", "data"))
                        inspect(v)
                    }
                is List<*> -> value.forEach { inspect(it) }
                is String -> {
                    need(
                        !Regex(
                                "(?i)(https?:|file:|asset:|data:|ftp:|mapbox:|maplibre:|\\.\\./|\\\\)"
                            )
                            .containsMatchIn(value)
                    )
                    if (value.contains("{PACK_ROOT}"))
                        need(
                            value == "pmtiles://{PACK_ROOT}/map.pmtiles" ||
                                value == "pmtiles://{PACK_ROOT}/terrain.pmtiles" ||
                                value == "{PACK_ROOT}/glyphs/{fontstack}/{range}.pbf" ||
                                value == "{PACK_ROOT}/sprite"
                        )
                }
            }
        }
        inspect(style)
        // URI encoding keeps spaces in app sandbox roots valid without allowing a template to
        // escape.
        val rootUri =
            root.toURI().toASCIIString().replaceFirst(Regex("^file:/+"), "file:///").trimEnd('/')
        return MapJson.encode(style).replace("{PACK_ROOT}", rootUri)
    }
}

data class MountainPlace(
    val id: String,
    val name: String,
    val aliases: List<String>,
    val kind: String,
    val point: MapPoint,
)

class PlaceIndex private constructor(private val places: List<MountainPlace>) {
    fun search(q: String): List<MountainPlace> {
        val tokens = normalize(q.trim()).split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (tokens.isEmpty()) return emptyList()
        return places
            .asSequence()
            .filter { p ->
                val words =
                    (listOf(p.name) + p.aliases).flatMap {
                        normalize(it).split(Regex("[^\\p{L}\\p{N}]+"))
                    }
                tokens.all { t -> words.any { it.startsWith(t) } }
            }
            .take(50)
            .toList()
    }

    companion object {
        private fun normalize(s: String) =
            Normalizer.normalize(s, Normalizer.Form.NFD)
                .replace(Regex("\\p{M}+"), "")
                .lowercase(Locale.ROOT)

        fun parse(bytes: ByteArray, bounds: BoundsE7): PlaceIndex {
            val o = MapJson.parse(bytes, 8 * 1024 * 1024).obj()
            o.fields("format", "places")
            need(o["format"].integer() == 1L)
            val list = o["places"].arr()
            need(list.size <= 25000)
            val places = list.map { v ->
                val p = v.obj()
                p.fields("id", "name", "aliases", "kind", "latE7", "lonE7")
                val id = p["id"].str()
                id.bounded(160)
                need(id.matches(Regex("(node|way|relation)/[1-9][0-9]*")))
                val name = p["name"].str().also { it.bounded(120) }
                val aliases = p["aliases"].arr().map { it.str().also { a -> a.bounded(120) } }
                need(aliases.size <= 8)
                val kind = p["kind"].str()
                need(kind in setOf("hut", "peak", "shelter", "water", "trailhead", "place"))
                val point = MapPoint(p["latE7"].integer(), p["lonE7"].integer())
                need(bounds.contains(point))
                MountainPlace(id, name, aliases, kind, point)
            }
            need(places.map { it.id }.toSet().size == places.size)
            return PlaceIndex(
                places.sortedWith(compareBy<MountainPlace> { it.name }.thenBy { it.id })
            )
        }
    }
}
