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
    fun `route directions keep verified shape positions`() {
        val raw = """{"trip":{"status":0,"units":"kilometers","summary":{"length":0.1,"time":10},"legs":[{"shape":"??AA","maneuvers":[{"begin_shape_index":0,"end_shape_index":1,"instruction":"Continue on the trail"},{"begin_shape_index":1,"end_shape_index":1,"instruction":"Arrive"}]}]}}"""
        val route = RouteParser.parse(raw, MapPoint(0, 0), MapPoint(10, 10))
        assertEquals(listOf(HikingManeuver(0, 1, "Continue on the trail"), HikingManeuver(1, 1, "Arrive")), route.maneuvers)
        rejects { RouteParser.parse(raw.replace(""" "end_shape_index":1""".trim(), """ "end_shape_index":2""".trim()), MapPoint(0, 0), MapPoint(10, 10)) }
    }

    @Test
    fun `route does not announce terminal maneuvers before location confirms proximity`() {
        val raw = """{"trip":{"status":0,"units":"kilometers","summary":{"length":0.1,"time":10},"legs":[{"shape":"??AA","maneuvers":[{"begin_shape_index":0,"end_shape_index":1,"instruction":"Arrive at your destination","type":4}]}]}}"""
        val route = RouteParser.parse(raw, MapPoint(0, 0), MapPoint(10, 10))
        assertTrue(route.maneuvers.single().arrival)
        assertEquals(null, route.instructionsAt(0.5))
    }

    @Test
    fun `guidance matches the route segment and reports off route distance`() {
        val route = HikingRoute(listOf(MapPoint(0, 0), MapPoint(0, 10000), MapPoint(10000, 10000)), 0.2, 180.0)
        val mid = route.matchPosition(MapPoint(0, 5000))
        assertEquals(0.5, mid.shapePosition, 0.001)
        assertEquals(0.0, mid.distanceM, 0.001)
        val next = route.matchPosition(MapPoint(5000, 10000))
        assertEquals(1.5, next.shapePosition, 0.001)
        val offRoute = route.matchPosition(MapPoint(-10000, 5000))
        assertEquals(111.195, offRoute.distanceM, 0.01)
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

    @Test
    fun `pinned open rejects another manifest and tracks bytes through verification`() {
        val root = Files.createTempDirectory("map-progress").toFile()
        try {
            val store = RegionStore(root)
            val bytes = fixtureManifest()
            val manifestHash = hash(bytes)
            val assets = fixtureAssets()
            val total = assets.values.sumOf { it.size }.toLong()
            val progress = mutableListOf<RegionInstallProgress>()
            store.install(
                bytes,
                manifestHash,
                MemoryTransport(assets),
                "https://example.test/release/",
                onProgress = progress::add,
            )
            val downloads = progress.filterIsInstance<RegionInstallProgress.Downloading>()
            assertEquals(0L, downloads.first().bytes)
            assertEquals(total, downloads.last().bytes)
            assertTrue(downloads.all { it.total == total && it.bytes in 0..total })
            assertTrue(downloads.zipWithNext().all { (first, next) -> first.bytes <= next.bytes })
            assertEquals(RegionInstallProgress.Verifying, progress.last())
            RegionStore(root).acquire("rila", "one", manifestHash).use { lease ->
                assertEquals("rila", lease.region.manifest.id)
            }
            val failure = assertThrows(MapFailure::class.java) {
                store.acquire("rila", "one", "0".repeat(64))
            }
            assertEquals(MapError.CORRUPT, failure.reason)
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
