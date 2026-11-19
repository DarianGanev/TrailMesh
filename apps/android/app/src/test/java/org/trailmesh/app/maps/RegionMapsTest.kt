package org.trailmesh.app.maps

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import org.junit.Assert.*
import org.junit.Test

class RegionMapsTest {
    @Test
    fun `place identity must be a positive canonical OSM element id`() {
        val bounds = BoundsE7(230000000, 420000000, 240000000, 430000000)
        for (id in listOf("node/0", "way/01", "relation/-1", "peak/1", "node/1/2", "arbitrary")) {
            val b =
                """{"format":1,"places":[{"id":"$id","name":"Peak","aliases":[],"kind":"peak","latE7":421000000,"lonE7":231000000}]}"""
                    .toByteArray()
            rejects { PlaceIndex.parse(b, bounds) }
        }
    }

    @Test
    fun `shared literal manifests agree with reference contract`() {
        val resource = javaClass.classLoader!!.getResourceAsStream("maps/region-v1-vectors.json")!!
        // Invalid Unicode inside a negative case must reach the production manifest parser.
        val document =
            com.google.gson.JsonParser.parseString(resource.bufferedReader().use { it.readText() })
                .asJsonObject
        for (item in document.getAsJsonArray("cases")) {
            val case = item.asJsonObject
            val literal = buildString {
                case.get("manifest").toString().forEach { c ->
                    if (c.isSurrogate()) append("\\u" + c.code.toString(16).padStart(4, '0'))
                    else append(c)
                }
            }
            val bytes = literal.toByteArray()
            val accepted =
                try {
                    RegionManifest.parse(bytes, hash(bytes))
                    true
                } catch (_: MapFailure) {
                    false
                }
            assertEquals(case.get("id").asString, case.get("valid").asBoolean, accepted)
        }
    }

    private fun rejects(block: () -> Unit) {
        try {
            block()
            fail("accepted invalid pack")
        } catch (_: MapFailure) {}
    }

    @Test
    fun `valid manifest is catalog pinned and unknown fields rejected`() {
        val bytes = fixtureManifest()
        assertEquals("rila", RegionManifest.parse(bytes, hash(bytes)).id)
        rejects { RegionManifest.parse(bytes, "0".repeat(64)) }
        val extra =
            bytes
                .decodeToString()
                .replace("\"format\":1", "\"format\":1,\"surprise\":1")
                .toByteArray()
        rejects { RegionManifest.parse(extra, hash(extra)) }
    }

    @Test
    fun `traversal case collisions oversized and duplicate fields rejected`() {
        for (bad in
            listOf(
                "../map.pmtiles",
                "a//map.pmtiles",
                "a/%2e/map.pmtiles",
                "a\\\\map.pmtiles",
                "/map.pmtiles",
            )) {
            val b = fixtureManifest().decodeToString().replace("map.pmtiles", bad).toByteArray()
            rejects { RegionManifest.parse(b, hash(b)) }
        }
        val b =
            fixtureManifest()
                .decodeToString()
                .replace("\"format\":1", "\"format\":1,\"format\":1")
                .toByteArray()
        rejects { RegionManifest.parse(b, hash(b)) }
        rejects { RegionManifest.parse(ByteArray(262145), "0".repeat(64)) }
    }

    @Test
    fun `style is closed over declared local files`() {
        val m = RegionManifest.parse(fixtureManifest(), hash(fixtureManifest()))
        assertTrue(
            ClosedStyle.resolve(fixtureAssets().getValue("style.json"), m, File("/offline/rila"))
                .contains("file:")
        )
        for (uri in
            listOf("https://tiles.example/map", "file:///etc/passwd", "{PACK_ROOT}/../secret")) {
            rejects {
                ClosedStyle.resolve(
                    """{"version":8,"sources":{"map":{"type":"vector","url":"$uri"}},"layers":[]}"""
                        .toByteArray(),
                    m,
                    File("/offline/rila"),
                )
            }
        }
    }

    @Test
    fun `places retain Cyrillic and normalize diacritics for prefix token search`() {
        val b =
            """{"format":1,"places":[{"id":"node/1","name":"Хижа Écho","aliases":["Echo Hut"],"kind":"hut","latE7":421000000,"lonE7":231000000}]}"""
                .toByteArray()
        val index = PlaceIndex.parse(b, BoundsE7(230000000, 420000000, 240000000, 430000000))
        assertEquals("Хижа Écho", index.search("echo").single().name)
        assertEquals(1, index.search("хижа").size)
        assertEquals("node/1", index.search("Echo-Hut").single().id)
        assertTrue(index.search(" --- ").isEmpty())
        assertTrue(index.search("  ").isEmpty())
        rejects {
            PlaceIndex.parse(
                b.decodeToString().replace("421000000", "0").toByteArray(),
                BoundsE7(230000000, 420000000, 240000000, 430000000),
            )
        }
    }

    @Test
    fun `polyline rejects overflow truncation and out of range coordinates`() {
        assertEquals(listOf(MapPoint(0, 0), MapPoint(10, 10)), RouteParser.decodePolyline("??AA"))
        for (s in listOf("~".repeat(60), "?", " ", "_gjaR?")) rejects {
            RouteParser.decodePolyline(s)
        }
        rejects { HikingRoute(List(2049) { MapPoint(0, 0) }, 1.0, 1.0).relevance() }
    }

    @Test
    fun `route rejects distant snaps invalid status and retains geometry`() {
        val start = MapPoint(0, 0)
        val end = MapPoint(10, 10)
        val raw =
            """{"trip":{"status":0,"units":"kilometers","summary":{"length":0.1,"time":10},"legs":[{"shape":"??AA"}]}}"""
        assertEquals(2, RouteParser.parse(raw, start, end).points.size)
        rejects { RouteParser.parse(raw, MapPoint(10000000, 10000000), end) }
        rejects { RouteParser.parse(raw.replace("\"status\":0", "\"status\":1"), start, end) }
        rejects { RouteParser.parse(raw.replace("\"length\":0.1", "\"length\":-1"), start, end) }
    }

    @Test
    fun `verified publication restart revalidation and lease removal`() {
        val root = Files.createTempDirectory("map-test").toFile()
        try {
            val store = RegionStore(root)
            val pack =
                store.install(
                    fixtureManifest(),
                    hash(fixtureManifest()),
                    MemoryTransport(fixtureAssets()),
                    "https://example.test/release/",
                )
            assertTrue(File(pack.directory, "map.pmtiles").isFile)
            val lease = store.acquire("rila", "one")
            try {
                store.remove("rila", "one")
                fail("removed leased pack")
            } catch (e: MapFailure) {
                assertEquals(MapError.BUSY, e.reason)
            }
            lease.close()
            assertEquals(1, RegionStore(root).discover().size)
            File(pack.directory, "map.pmtiles").writeText("tampered")
            assertTrue(RegionStore(root).discover().isEmpty())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `cancel during final transfer cannot publish and matching partial resumes`() {
        val root = Files.createTempDirectory("map-cancel").toFile()
        try {
            val operation = InstallCancellation()
            val store = RegionStore(root)
            val assets = fixtureAssets()
            val transport =
                object : AssetTransport {
                    override fun open(url: String, offset: Long): AssetResponse {
                        operation.cancel()
                        return AssetResponse(
                            200,
                            null,
                            assets.getValue(url.substringAfterLast('/')).inputStream(),
                        )
                    }
                }
            rejects {
                store.install(
                    fixtureManifest(),
                    hash(fixtureManifest()),
                    transport,
                    "https://example.test/release/",
                    operation,
                )
            }
            assertTrue(store.discover().isEmpty())
            store.install(
                fixtureManifest(),
                hash(fixtureManifest()),
                MemoryTransport(assets),
                "https://example.test/release/",
            )
            assertEquals(1, store.discover().size)
        } finally {
            root.deleteRecursively()
        }
    }

    companion object {
        fun hash(bytes: ByteArray) =
            MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") {
                "%02x".format(it)
            }

        fun fixtureAssets() =
            linkedMapOf(
                "map.pmtiles" to RegionSafetyTest.archive(),
                "routing.tar" to byteArrayOf(4, 5, 6),
                "places.json" to """{"format":1,"places":[]}""".toByteArray(),
                "style.json" to
                    """{"version":8,"sources":{"map":{"type":"vector","url":"pmtiles://{PACK_ROOT}/map.pmtiles"}},"layers":[]}"""
                        .toByteArray(),
                "licenses/OSM.txt" to "OSM ODbL".toByteArray(),
            )

        fun fixtureManifest(): ByteArray {
            val files =
                fixtureAssets().entries.joinToString(",") { (p, b) ->
                    """{"path":"$p","asset":"${p.replace('/','-')}","bytes":${b.size},"sha256":"${hash(b)}"}"""
                }
            return """{"format":1,"id":"rila","revision":"one","name":"Rila","dataDate":"2026-11-01","boundsE7":[230000000,420000000,240000000,430000000],"minZoom":0,"maxZoom":14,"engine":"valhalla-3.9.2","attribution":"© OpenStreetMap contributors","files":[$files]}"""
                .toByteArray()
        }
    }

    class MemoryTransport(private val assets: Map<String, ByteArray>) : AssetTransport {
        override fun open(url: String, offset: Long): AssetResponse {
            val asset = url.substringAfterLast('/')
            val b = assets.entries.single { it.key.replace('/', '-') == asset }.value
            return AssetResponse(
                if (offset > 0) 206 else 200,
                if (offset > 0) "bytes $offset-${b.size-1}/${b.size}" else null,
                b.inputStream().also { it.skip(offset) },
            )
        }
    }
}
