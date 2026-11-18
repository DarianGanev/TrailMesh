package org.trailmesh.app.maps

import com.valhalla.valhalla.Valhalla
import com.valhalla.valhalla.ValhallaException
import java.io.File

/** Native dependency is isolated from JVM port tests. Config lives outside the immutable pack. */
class NativeValhallaFactory(private val cacheDirectory: File) : RoutingEngineFactory {
    private companion object {
        val ERROR_CODE = Regex("""^ValhallaError\(code=(-?[0-9]{1,10}),""")
    }

    override fun open(graph: File): LocalRoutingEngine {
        need(graph.isAbsolute && graph.isFile, MapError.UNAVAILABLE)
        cacheDirectory.mkdirs()
        val raw =
            Valhalla::class.java.getResourceAsStream("/com/valhalla/valhalla/default.json")?.use {
                it.readBytes()
            } ?: throw MapFailure(MapError.INVALID_ENGINE)
        val config = MapJson.parse(raw, 262144).obj().toMutableMap()
        val mjolnir = config["mjolnir"].obj().toMutableMap()
        mjolnir.remove("tile_url")
        mjolnir["tile_dir"] = ""
        mjolnir["tile_extract"] = graph.absolutePath
        config["mjolnir"] = mjolnir
        val file = File.createTempFile("valhalla-", ".json", cacheDirectory)
        file.writeText(MapJson.encode(config))
        val engine =
            try {
                Valhalla(file.absolutePath)
            } finally {
                file.delete()
            }
        return object : LocalRoutingEngine {
            override fun route(request: String): String =
                try {
                    engine.routeRaw(request)
                } catch (e: ValhallaException.Internal) {
                    // The pinned SDK exposes only the formatted ErrorResponse. Keep its numeric
                    // code without carrying native message text or request data into diagnostics.
                    val code = ERROR_CODE.find(e.message.orEmpty())?.groupValues?.get(1)?.toLongOrNull()
                    throw RouteParser.engineFailure(code)
                }

            override fun close() = engine.close()
        }
    }
}
