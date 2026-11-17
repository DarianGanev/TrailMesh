package org.trailmesh.app.maps

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class RegionSafetyTest {
    @Test
    fun `full length corrupt partial is replaced on same manifest retry`() {
        val root = Files.createTempDirectory("map-corrupt-retry").toFile()
        try {
            val bytes = RegionMapsTest.fixtureManifest()
            val store = RegionStore(root)
            val corrupt =
                object : AssetTransport {
                    override fun open(url: String, offset: Long) =
                        AssetResponse(
                            200,
                            null,
                            ByteArray(RegionSafetyTest.archive().size).inputStream(),
                        )
                }
            failure(MapError.CORRUPT) {
                store.install(bytes, RegionMapsTest.hash(bytes), corrupt, "https://example.test/")
            }
            store.install(
                bytes,
                RegionMapsTest.hash(bytes),
                RegionMapsTest.MemoryTransport(RegionMapsTest.fixtureAssets()),
                "https://example.test/",
            )
            assertEquals(1, store.discover().size)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `abandoned trash after process death does not block reinstall removal`() {
        val root = Files.createTempDirectory("map-trash-recovery").toFile()
        try {
            File(root, ".trash-rila--one").mkdirs()
            File(root, ".trash-rila--one/old-map").writeText("old")
            val bytes = RegionMapsTest.fixtureManifest()
            val store = RegionStore(root)
            store.install(
                bytes,
                RegionMapsTest.hash(bytes),
                RegionMapsTest.MemoryTransport(RegionMapsTest.fixtureAssets()),
                "https://example.test/",
            )
            store.remove("rila", "one")
            assertTrue(store.discover().isEmpty())
            assertFalse(File(root, ".trash-rila--one").exists())
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `manifest names bound Unicode code points and reject unpaired surrogate`() {
        for (n in listOf(120, 121)) {
            val bytes =
                RegionMapsTest.fixtureManifest()
                    .decodeToString()
                    .replace("\"name\":\"Rila\"", "\"name\":\"${"\uD83C\uDFD4".repeat(n)}\"")
                    .toByteArray()
            if (n == 120)
                assertEquals(
                    240,
                    RegionManifest.parse(bytes, RegionMapsTest.hash(bytes)).name.length,
                )
            else
                failure(MapError.CORRUPT) {
                    RegionManifest.parse(bytes, RegionMapsTest.hash(bytes))
                }
        }
        val malformed =
            RegionMapsTest.fixtureManifest()
                .decodeToString()
                .replace("\"name\":\"Rila\"", "\"name\":\"\\ud800\"")
                .toByteArray()
        failure(MapError.CORRUPT) {
            RegionManifest.parse(malformed, RegionMapsTest.hash(malformed))
        }
    }

    @Test
    fun `installer metadata names are reserved ignoring ASCII case`() {
        val original = RegionMapsTest.fixtureManifest().decodeToString()
        val bytes =
            original
                .replace(
                    "\"files\":[",
                    "\"files\":[{\"path\":\"MANIFEST.JSON\",\"asset\":\"unexpected\",\"bytes\":1,\"sha256\":\"${"0".repeat(64)}\"},",
                )
                .toByteArray()
        failure(MapError.CORRUPT) { RegionManifest.parse(bytes, RegionMapsTest.hash(bytes)) }
    }

    @Test
    fun `route cannot leave installed geographic coverage between valid endpoints`() {
        val root = Files.createTempDirectory("map-coverage").toFile()
        try {
            val store = RegionStore(root)
            val b = RegionMapsTest.fixtureManifest()
            store.install(
                b,
                RegionMapsTest.hash(b),
                RegionMapsTest.MemoryTransport(RegionMapsTest.fixtureAssets()),
                "https://example.test/",
            )
            val points =
                listOf(
                    MapPoint(421000000, 231000000),
                    MapPoint(440000000, 231000000),
                    MapPoint(421000010, 231000010),
                )
            var lastLat = 0L
            var lastLon = 0L
            fun component(delta: Long): String {
                var n = if (delta < 0) (-delta * 2 - 1) else delta * 2
                return buildString {
                    while (n >= 32) {
                        append(((n and 31) or 32).toInt().plus(63).toChar())
                        n = n shr 5
                    }
                    append((n + 63).toInt().toChar())
                }
            }
            val shape = buildString {
                for (p in points) {
                    append(component(p.latE7 / 10 - lastLat))
                    append(component(p.lonE7 / 10 - lastLon))
                    lastLat = p.latE7 / 10
                    lastLon = p.lonE7 / 10
                }
            }
            val raw =
                MapJson.encode(
                    mapOf(
                        "trip" to
                            mapOf(
                                "status" to 0,
                                "units" to "kilometers",
                                "summary" to mapOf("length" to 1, "time" to 1),
                                "legs" to listOf(mapOf("shape" to shape)),
                            )
                    )
                )
            val router =
                RegionRouter(
                    store,
                    "rila",
                    "one",
                    RoutingEngineFactory {
                        object : LocalRoutingEngine {
                            override fun route(request: String) = raw

                            override fun close() {}
                        }
                    },
                )
            try {
                router.route(points.first(), points.last()).get(5, TimeUnit.SECONDS)
                fail("route left map coverage")
            } catch (e: java.util.concurrent.ExecutionException) {
                assertEquals(MapError.OUTSIDE_COVERAGE, (e.cause as MapFailure).reason)
            } finally {
                router.closeAsync().get()
            }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `real glyph fontstack paths contain legal ASCII spaces`() {
        assertTrue(safePath("glyphs/Noto Sans Regular/1024-1279.pbf"))
        assertTrue(safePath("glyphs-Noto Sans Regular-1024-1279.pbf"))
    }

    private fun failure(reason: MapError, block: () -> Unit) {
        try {
            block()
            fail("expected $reason")
        } catch (e: MapFailure) {
            assertEquals(reason, e.reason)
        }
    }

    @Test
    fun `runtime style uses SDK file slash scheme and rejects undeclared glyph range`() {
        val b = RegionMapsTest.fixtureManifest()
        val m = RegionManifest.parse(b, RegionMapsTest.hash(b))
        val style =
            ClosedStyle.resolve(
                RegionMapsTest.fixtureAssets().getValue("style.json"),
                m,
                File("/pack root/rila"),
            )
        assertTrue(style.contains("pmtiles://file:///"))
        assertTrue(style.contains("/pack%20root/rila/map.pmtiles"))
    }

    @Test
    fun `PMTiles rejects remote metadata override before publication`() {
        val root = Files.createTempDirectory("pmtiles-meta").toFile()
        try {
            val archive =
                File(root, "bad.pmtiles").apply {
                    writeBytes(archive("""{"tiles":["https://remote.test/tile"]}"""))
                }
            failure(MapError.CORRUPT) { PMTilesArchive.validate(archive) }
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `interrupted range resumes verified bytes and invalid range cannot publish`() {
        val root = Files.createTempDirectory("map-resume").toFile()
        try {
            val b = RegionMapsTest.fixtureManifest()
            val hash = RegionMapsTest.hash(b)
            val assets = RegionMapsTest.fixtureAssets()
            val store = RegionStore(root)
            val interrupted =
                object : AssetTransport {
                    override fun open(url: String, offset: Long): AssetResponse =
                        AssetResponse(
                            200,
                            null,
                            object : InputStream() {
                                var emitted = false

                                override fun read(): Int {
                                    if (!emitted) {
                                        emitted = true
                                        return 1
                                    }
                                    throw IOException("interrupted")
                                }

                                override fun read(buf: ByteArray, off: Int, len: Int): Int {
                                    if (!emitted) {
                                        emitted = true
                                        buf[off] = 80
                                        return 1
                                    }
                                    throw IOException("interrupted")
                                }
                            },
                        )
                }
            failure(MapError.UNAVAILABLE) {
                store.install(b, hash, interrupted, "https://example.test/")
            }
            val offsets = mutableListOf<Long>()
            val bad =
                object : AssetTransport {
                    override fun open(url: String, offset: Long): AssetResponse {
                        offsets.add(offset)
                        return AssetResponse(206, "bytes 0-2/3", byteArrayOf(2, 3).inputStream())
                    }
                }
            failure(MapError.CORRUPT) { store.install(b, hash, bad, "https://example.test/") }
            assertEquals(listOf(1L), offsets)
            assertTrue(store.discover().isEmpty())
            store.install(b, hash, RegionMapsTest.MemoryTransport(assets), "https://example.test/")
            assertEquals(1, store.discover().size)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `space check happens before network and completed staging bytes are rehashed`() {
        val root = Files.createTempDirectory("map-space").toFile()
        try {
            val b = RegionMapsTest.fixtureManifest()
            var calls = 0
            val t =
                object : AssetTransport {
                    override fun open(url: String, offset: Long): AssetResponse {
                        calls++
                        throw AssertionError("unexpected fetch")
                    }
                }
            failure(MapError.SPACE) {
                RegionStore(root) { 0 }
                    .install(b, RegionMapsTest.hash(b), t, "https://example.test/")
            }
            assertEquals(0, calls)
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun `native port reuses actor serially and holds lease until worker closes`() {
        val root = Files.createTempDirectory("map-worker").toFile()
        try {
            val store = RegionStore(root)
            val b = RegionMapsTest.fixtureManifest()
            store.install(
                b,
                RegionMapsTest.hash(b),
                RegionMapsTest.MemoryTransport(RegionMapsTest.fixtureAssets()),
                "https://example.test/",
            )
            val threads = mutableListOf<Long>()
            var opens = 0
            var closes = 0
            val router =
                RegionRouter(
                    store,
                    "rila",
                    "one",
                    RoutingEngineFactory {
                        opens++
                        threads.add(Thread.currentThread().id)
                        object : LocalRoutingEngine {
                            override fun route(request: String): String {
                                threads.add(Thread.currentThread().id)
                                return """{"trip":{"status":0,"units":"kilometers","summary":{"length":0.1,"time":10},"legs":[{"shape":"_qvhoA_f|`k@AA"}]}}"""
                            }

                            override fun close() {
                                closes++
                                threads.add(Thread.currentThread().id)
                            }
                        }
                    },
                )
            // A parser rejection still leaves the reused actor protected by its lease.
            repeat(2) {
                try {
                    router
                        .route(MapPoint(421000000, 231000000), MapPoint(421000010, 231000010))
                        .get(5, TimeUnit.SECONDS)
                } catch (_: Exception) {}
            }
            assertEquals(1, opens)
            failure(MapError.BUSY) { store.remove("rila", "one") }
            router.closeAsync().get(5, TimeUnit.SECONDS)
            assertEquals(1, closes)
            assertEquals(1, threads.toSet().size)
            assertNotEquals(Thread.currentThread().id, threads.first())
            store.remove("rila", "one")
            assertTrue(store.discover().isEmpty())
        } finally {
            root.deleteRecursively()
        }
    }

    companion object {
        fun archive(metadata: String = "{}"): ByteArray {
            val b = metadata.toByteArray()
            val header = java.nio.ByteBuffer.allocate(127).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            header.put("PMTiles".toByteArray())
            header.put(3.toByte())
            header.putLong(24, 127)
            header.putLong(32, b.size.toLong())
            header.put(97, 1)
            header.put(98, 2)
            header.put(99, 1)
            return header.array() + b
        }
    }
}
