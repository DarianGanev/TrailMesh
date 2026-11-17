package org.trailmesh.app.maps

import android.app.Activity
import android.os.Bundle
import android.widget.*
import java.io.File
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.maps.Style
import org.maplibre.android.snapshotter.MapSnapshotter

/** Explicit adb entry point in debug APKs only. Hiking product UI remains a separate work item. */
class MapsDiagnosticsActivity : Activity() {
    private val worker = DiagnosticWorker {
        router?.closeAsync()?.get()
        router = null
    }
    private var cancellation = InstallCancellation()
    private lateinit var store: RegionStore
    private lateinit var output: TextView
    private var selected: InstalledRegion? = null
    private var router: RegionRouter? = null
    private var snapshotOperation: SnapshotOperation? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = RegionStore(File(filesDir, "offline-regions"))
        MapLibre.getInstance(this)
        val content =
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(24, 24, 24, 24)
            }
        fun field(hintText: String) =
            EditText(this).apply {
                hint = hintText
                content.addView(this)
            }
        fun button(label: String, action: () -> Unit) {
            content.addView(
                Button(this).apply {
                    text = label
                    setOnClickListener { action() }
                }
            )
        }
        val base = field("HTTPS region release directory (ends in /)")
        val pinnedHash = field("Catalog manifest SHA-256")
        val query = field("Local place name, Cyrillic or Latin")
        val endpoints = field("from latE7,lonE7,to latE7,lonE7")
        output = TextView(this)
        content.addView(output)
        fun job(block: () -> String) {
            worker.execute {
                if (isDestroyed) return@execute
                val result =
                    try {
                        block()
                    } catch (e: MapFailure) {
                        "Map status: ${e.reason}"
                    } catch (e: Exception) {
                        "Map status: ${(e.cause as? MapFailure)?.reason ?: MapError.UNAVAILABLE}"
                    }
                runOnUiThread { if (!isDestroyed) output.text = result }
            }
        }
        button("Prepare verified offline region") {
            val url = base.text.toString().trim()
            val hash = pinnedHash.text.toString().trim()
            cancellation.cancel()
            val operation = InstallCancellation().also { cancellation = it }
            output.text = "Preparing region; unavailable until all files verify"
            job {
                need(hash.matches(Regex("[0-9a-f]{64}")))
                need(url.startsWith("https://") && url.endsWith('/'))
                val transport = HttpsAssetTransport()
                val manifest =
                    transport.open(url + "manifest.json", 0).use { response ->
                        need(response.status == 200)
                        response.body.readNBytesBounded(262144)
                    }
                val region = store.install(manifest, hash, transport, url, operation)
                selected = region
                "Ready: ${region.manifest.name}\n${region.manifest.files.sumOf{it.bytes}} bytes\n${region.manifest.attribution}"
            }
        }
        button("Cancel preparation") {
            cancellation.cancel()
            output.text = "Cancellation requested"
        }
        button("Discover installed regions") {
            job {
                val regions = store.discover()
                selected = regions.firstOrNull()
                regions
                    .joinToString("\n") {
                        "${it.manifest.name}: ${it.manifest.revision}\n${it.manifest.attribution}"
                    }
                    .ifEmpty { "No verified region installed" }
            }
        }
        button("Search installed places") {
            val searchQuery = query.text.toString()
            job {
                val region = selected ?: throw MapFailure(MapError.UNAVAILABLE)
                store.acquire(region.manifest.id, region.manifest.revision).use { lease ->
                    lease.region
                        .places()
                        .search(searchQuery)
                        .joinToString("\n") { "${it.name}: ${it.point.latE7},${it.point.lonE7}" }
                        .ifEmpty { "No matching mapped place" }
                }
            }
        }
        button("Calculate local hiking route") {
            val requestedEndpoints = endpoints.text.toString()
            job {
                val region = selected ?: throw MapFailure(MapError.UNAVAILABLE)
                val e = requestedEndpoints.split(',').map { it.trim().toLong() }
                need(e.size == 4, MapError.OUTSIDE_COVERAGE)
                router?.closeAsync()?.get()
                val r =
                    RegionRouter(
                            store,
                            region.manifest.id,
                            region.manifest.revision,
                            NativeValhallaFactory(File(cacheDir, "offline-router")),
                        )
                        .also { router = it }
                val route = r.route(MapPoint(e[0], e[1]), MapPoint(e[2], e[3])).get()
                val relevance =
                    try {
                        route.relevance()
                        "corridor available"
                    } catch (_: MapFailure) {
                        "relevance too complex"
                    }
                "Local route: ${route.distanceKm} km, ${route.seconds} seconds, ${route.points.size} points; $relevance. No safety or live-condition guarantee."
            }
        }
        val preview = ImageView(this)
        content.addView(preview)
        button("Snapshot local map") {
            worker.execute {
                try {
                    val region = selected ?: throw MapFailure(MapError.UNAVAILABLE)
                    val lease = store.acquire(region.manifest.id, region.manifest.revision)
                    val prepared = SnapshotOperation.prepare(lease) { lease.region.style() }
                    runOnUiThread {
                        val operation = prepared.operation
                        if (isDestroyed) {
                            operation.close()
                            return@runOnUiThread
                        }
                        snapshotOperation?.close()
                        snapshotOperation = operation
                        try {
                            val b = region.manifest.bounds
                            val camera =
                                CameraPosition.Builder()
                                    .target(
                                        LatLng((b.south + b.north) / 2e7, (b.west + b.east) / 2e7)
                                    )
                                    .zoom(12.0)
                                    .build()
                            val renderer =
                                MapSnapshotter(
                                    this,
                                    MapSnapshotter.Options(1024, 768)
                                        .withStyleBuilder(Style.Builder().fromJson(prepared.value))
                                        .withCameraPosition(camera)
                                        .withAttribution(true),
                                )
                            operation.attachCancel { renderer.cancel() }
                            renderer.start(
                                { result ->
                                    if (snapshotOperation === operation) {
                                        preview.setImageBitmap(result.bitmap)
                                        snapshotOperation = null
                                    }
                                    operation.close()
                                },
                                {
                                    if (snapshotOperation === operation) {
                                        output.text = "Snapshot unavailable"
                                        snapshotOperation = null
                                    }
                                    operation.close()
                                },
                            )
                        } catch (_: Exception) {
                            if (snapshotOperation === operation) snapshotOperation = null
                            operation.close()
                            output.text = "Snapshot unavailable"
                        }
                    }
                } catch (_: Exception) {
                    runOnUiThread { if (!isDestroyed) output.text = "Snapshot unavailable" }
                }
            }
        }
        button("Remove selected region") {
            job {
                val region = selected ?: throw MapFailure(MapError.UNAVAILABLE)
                router?.closeAsync()?.get()
                router = null
                store.remove(region.manifest.id, region.manifest.revision)
                selected = null
                "Region removed"
            }
        }
        setContentView(ScrollView(this).apply { addView(content) })
    }

    override fun onDestroy() {
        cancellation.cancel()
        snapshotOperation?.close()
        snapshotOperation = null
        worker.closeAsync()
        super.onDestroy()
    }
}

private fun java.io.InputStream.readNBytesBounded(limit: Int): ByteArray {
    val result = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(16384)
    while (true) {
        val n = read(buffer)
        if (n < 0) break
        need(result.size() + n <= limit)
        result.write(buffer, 0, n)
    }
    return result.toByteArray()
}
