package org.trailmesh.app.maps

import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

internal sealed interface ExploreRegionState {
    data object Checking : ExploreRegionState
    data object Available : ExploreRegionState
    data object Damaged : ExploreRegionState
    data class Installing(val progress: RegionInstallProgress? = null) : ExploreRegionState
    data object Cancelling : ExploreRegionState
    data class Failed(val reason: MapError, val replace: Boolean) : ExploreRegionState
    data class Ready(val region: InstalledRegion, val style: String) : ExploreRegionState
}

/** Survives configuration changes. The activity destroys its renderer before releasing this owner. */
internal class RilaRegion(private val root: File) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutableState = MutableStateFlow<ExploreRegionState>(ExploreRegionState.Checking)
    val state: StateFlow<ExploreRegionState> = mutableState
    private var lease: RegionLease? = null
    private var install: InstallCancellation? = null

    init {
        prepare(null, false)
    }

    fun refreshAfterDiagnostics() {
        when (state.value) {
            ExploreRegionState.Available, ExploreRegionState.Damaged, is ExploreRegionState.Failed -> {
                mutableState.value = ExploreRegionState.Checking
                prepare(null, false)
            }
            else -> Unit
        }
    }

    fun download() {
        val replace = when (val current = state.value) {
            ExploreRegionState.Available -> false
            ExploreRegionState.Damaged -> true
            is ExploreRegionState.Failed -> current.replace
            else -> return
        }
        val cancellation = InstallCancellation()
        install = cancellation
        mutableState.value = ExploreRegionState.Installing()
        prepare(cancellation, replace)
    }

    fun cancelDownload() {
        val cancellation = install ?: return
        mutableState.value = ExploreRegionState.Cancelling
        cancellation.cancel()
    }

    private fun prepare(cancellation: InstallCancellation?, replace: Boolean) {
        scope.launch {
            var opened: RegionLease? = null
            try {
                val ready = withContext(Dispatchers.IO) {
                    val store = RegionStore(root)
                    if (cancellation != null) {
                        val transport = HttpsAssetTransport()
                        val bytes = transport.open("${RELEASE_URL}manifest.json", 0).use { response ->
                            need(response.status == 200, MapError.UNAVAILABLE)
                            response.body.readNBytesBounded(262144, cancellation)
                        }
                        val manifest = RegionManifest.parse(bytes, MANIFEST_HASH)
                        need(manifest.id == ID && manifest.revision == REVISION)
                        cancellation.check()
                        if (replace) store.remove(ID, REVISION)
                        store.install(bytes, MANIFEST_HASH, transport, RELEASE_URL, cancellation) { progress ->
                            mutableState.update { current ->
                                if (current is ExploreRegionState.Installing)
                                    ExploreRegionState.Installing(progress)
                                else current
                            }
                        }
                    }
                    val acquired = store.acquire(ID, REVISION, MANIFEST_HASH)
                    opened = acquired
                    ExploreRegionState.Ready(acquired.region, exploreStyle(acquired.region.style()))
                }
                lease = opened
                opened = null
                mutableState.value = ready
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                val reason = (failure as? MapFailure)?.reason ?: MapError.UNAVAILABLE
                mutableState.value = when {
                    cancellation != null -> ExploreRegionState.Failed(reason, replace)
                    reason == MapError.CORRUPT -> ExploreRegionState.Damaged
                    else -> ExploreRegionState.Available
                }
            } finally {
                opened?.close()
                install = null
            }
        }
    }

    fun close() {
        install?.cancel()
        scope.cancel()
        lease?.close()
        lease = null
    }

    private fun java.io.InputStream.readNBytesBounded(
        limit: Int,
        cancellation: InstallCancellation,
    ): ByteArray {
        val result = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            cancellation.check()
            val count = read(buffer)
            if (count < 0) break
            need(result.size() + count <= limit)
            result.write(buffer, 0, count)
        }
        return result.toByteArray()
    }

    private companion object {
        const val ID = "rila"
        const val REVISION = "osm-2026-11-16-v1"
        const val MANIFEST_HASH = "862f354fa7ee81ba88c841767773607efc91f5c875c564e9faedcb196ac2c10f"
        const val RELEASE_URL =
            "https://github.com/DarianGanev/TrailMesh/releases/download/maps-rila-$REVISION/"
    }
}

// Restyle a resolved, verified pack for display without modifying its files or sources.
private fun exploreStyle(resolved: String): String {
    val style = JSONObject(resolved)
    val layers = style.getJSONArray("layers")
    for (index in 0 until layers.length()) {
        val layer = layers.getJSONObject(index)
        when (layer.getString("id")) {
            "mountain-relief" -> layer.getJSONObject("paint").apply {
                put("hillshade-shadow-color", "#586664")
                put("hillshade-exaggeration", 0.49)
            }
            "footpaths" -> layer.getJSONObject("paint").put("line-color", "#4b5350")
            "streams" -> layer.getJSONObject("paint").put("line-color", "#357f9e")
            "huts", "peaks" -> {
                val layout = layer.getJSONObject("layout")
                val label = layout.optJSONArray("text-field")?.optJSONArray(2)
                if (label != null) layout.put("text-field", label)
                layout.put("icon-image", if (layer.getString("id") == "huts") "trailmesh-hut" else "trailmesh-peak")
                layout.put("text-anchor", "left")
                layout.put("text-offset", JSONArray().put(0.8).put(0))
                layout.put("text-optional", true)
                layer.getJSONObject("paint").put("text-color", "#252c26")
            }
        }
    }
    return style.toString()
}
