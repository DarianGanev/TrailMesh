package org.trailmesh.app.maps

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import okhttp3.OkHttpClient
import org.trailmesh.app.relevance.*
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.Style
import org.maplibre.android.module.http.HttpRequestUtil
import org.maplibre.android.snapshotter.MapSnapshotter

/** Real generated pack required in CI. No graph or cartography is substituted with a fixture. */
@RunWith(AndroidJUnit4::class)
class OfflineRegionSmokeTest {
    @Test
    fun realPackColdLocalSearchNativeRouteAndSnapshotWithoutHttp() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val args = InstrumentationRegistry.getArguments()
        val path = args.getString("trailmeshMapPack")
        if (args.getString("trailmeshRequireMapPack") == "true")
            assertNotNull("real region pack required", path)
        assumeTrue("external real map pack not provided", path != null)
        val source = File(path!!)
        val manifestFile = File(source, "manifest.json")
        assertTrue(manifestFile.isFile)
        val manifest = manifestFile.readBytes()
        val hash =
            args.getString("trailmeshManifestSha256")
                ?: File(source, "manifest.sha256").readText().trim().substringBefore(' ')
        val context = instrumentation.targetContext
        val root = File(context.filesDir, "offline-smoke-regions")
        val verifyOnly = args.getString("trailmeshMapPhase") == "verify"
        if (!verifyOnly) root.deleteRecursively()
        else assertTrue("cold restart lost installed pack", root.isDirectory)
        val parsed = RegionManifest.parse(manifest, hash)
        val assets = parsed.files.associateBy { it.asset }
        val store = RegionStore(root)
        if (!verifyOnly)
            store.install(
                manifest,
                hash,
                object : AssetTransport {
                    override fun open(url: String, offset: Long): AssetResponse {
                        val asset = java.net.URI(url).path.substringAfterLast('/')
                        val f = File(source, assets.getValue(asset).path)
                        val input = f.inputStream()
                        input.channel.position(offset)
                        return AssetResponse(
                            if (offset > 0) 206 else 200,
                            if (offset > 0) "bytes $offset-${f.length()-1}/${f.length()}" else null,
                            input,
                        )
                    }
                },
                "https://local-fixture.invalid/",
            )
        // Recreate the store rather than using an installer-returned object: exercises launch
        // discovery.
        val restarted = RegionStore(root)
        assertEquals(1, restarted.discover().size)
        val smoke = MapJson.parse(File(source, "smoke.json").readBytes(), 65536).obj()
        fun point(key: String): MapPoint {
            val p = smoke[key].obj()
            return MapPoint(p["latE7"].integer(), p["lonE7"].integer())
        }
        val start = point("from")
        val end = point("to")
        val lease = restarted.acquire(parsed.id, parsed.revision)
        try {
            assertEquals(hash, File(lease.region.directory, "manifest.sha256").readText())
            assertTrue(lease.region.places().search(smoke["query"].str()).isNotEmpty())
            val attempts = AtomicInteger()
            val client =
                OkHttpClient.Builder()
                    .addInterceptor {
                        attempts.incrementAndGet()
                        throw IOException("HTTP disabled by offline proof")
                    }
                    .build()
            val cacheReady = CountDownLatch(1)
            var cacheError: String? = null
            val coldCache =
                File(context.cacheDir, "offline-smoke-map-${System.nanoTime()}").apply { mkdirs() }
            instrumentation.runOnMainSync {
                MapLibre.getInstance(context)
                HttpRequestUtil.setOkHttpClient(client)
                org.maplibre.android.storage.FileSource.setResourcesCachePath(
                    context,
                    coldCache.absolutePath,
                    object : org.maplibre.android.storage.FileSource.ResourcesCachePathChangeCallback {
                        override fun onSuccess(path: String) {
                            cacheReady.countDown()
                        }

                        override fun onError(message: String) {
                            cacheError = message
                            cacheReady.countDown()
                        }
                    },
                )
            }
            assertTrue("cold renderer cache timed out", cacheReady.await(30, TimeUnit.SECONDS))
            assertNull(cacheError)
            val router =
                RegionRouter(
                    restarted,
                    parsed.id,
                    parsed.revision,
                    NativeValhallaFactory(File(context.cacheDir, "smoke-router")),
                )
            try {
                val route = router.route(start, end).get(120, TimeUnit.SECONDS)
                assertTrue(route.distanceKm > 0)
                assertTrue(route.seconds > 0)
                assertTrue(route.points.size >= 2)
                val relevance = route.relevance() // Must fail explicitly if real geometry exceeds the policy bound.
                val near = route.points[route.points.size / 2]
                val nearReport = RelevantReport("rila-route", 100, 200, GeoPoint(near.latE7, near.lonE7))
                val sofiaReport = nearReport.copy(id = "sofia", point = GeoPoint(426977000, 233219000))
                assertEquals(RelevanceDecision.eligible, RelevancePolicy.evaluate(nearReport, relevance, 100))
                assertEquals(RelevanceDecision.notRelevant, RelevancePolicy.evaluate(sofiaReport, relevance, 100))
                val latch = CountDownLatch(1)
                var error: String? = null
                var bitmap: android.graphics.Bitmap? = null
                var snapshotter: MapSnapshotter? = null
                val missing = mutableListOf<String>()
                val style = lease.region.style()
                instrumentation.runOnMainSync {
                    val options =
                        MapSnapshotter.Options(1024, 768)
                            .withStyleBuilder(Style.Builder().fromJson(style))
                            .withCameraPosition(
                                CameraPosition.Builder()
                                    .target(LatLng(start.latE7 / 1e7, start.lonE7 / 1e7))
                                    .zoom(13.0)
                                    .build()
                            )
                            .withAttribution(true)
                    snapshotter = MapSnapshotter(context, options)
                    snapshotter!!.setObserver(
                        object : MapSnapshotter.Observer {
                            override fun onDidFinishLoadingStyle() {}

                            override fun onStyleImageMissing(id: String) {
                                missing.add(id)
                            }
                        }
                    )
                    snapshotter!!.start(
                        { snapshot ->
                            bitmap = snapshot.bitmap
                            latch.countDown()
                        },
                        { message ->
                            error = message
                            latch.countDown()
                        },
                    )
                }
                try {
                    assertTrue("snapshot timed out", latch.await(120, TimeUnit.SECONDS))
                    assertNull(error)
                    assertNotNull(bitmap)
                    assertTrue("missing style images: $missing", missing.isEmpty())
                    val image = bitmap!!
                    val colors = mutableSetOf<Int>()
                    for (y in 0 until image.height step 8) for (x in 0 until image.width step 8) colors
                        .add(image.getPixel(x, y))
                    assertTrue("blank map snapshot", colors.size > 32)
                    File(context.filesDir, "offline-smoke-snapshot.png").outputStream().use {
                        image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                    }
                    assertEquals("map attempted HTTP requests", 0, attempts.get())
                    File(context.filesDir, "offline-smoke-evidence.json")
                        .writeText(
                            MapJson.encode(
                                mapOf(
                                    "format" to 1,
                                    "phase" to if (verifyOnly) "verify" else "install",
                                    "manifestSha256" to hash,
                                    "androidApi" to android.os.Build.VERSION.SDK_INT,
                                    "renderer" to "13.5.4",
                                    "router" to "0.6.6",
                                    "routePointCount" to route.points.size,
                                    "httpAttempts" to attempts.get(),
                                    "snapshotDistinctColors" to colors.size,
                                    "attribution" to parsed.attribution,
                                )
                            )
                        )
                } finally {
                    instrumentation.runOnMainSync { snapshotter?.cancel() }
                }
            } finally {
                router.closeAsync().get(30, TimeUnit.SECONDS)
            }
        } finally {
            try {
                lease.close()
            } finally {
                instrumentation.runOnMainSync { HttpRequestUtil.setOkHttpClient(null) }
            }
        }
    }
}
