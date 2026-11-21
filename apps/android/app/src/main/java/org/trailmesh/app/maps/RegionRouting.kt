package org.trailmesh.app.maps

import java.io.Closeable
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import kotlin.math.*
import org.trailmesh.app.relevance.GeoPoint
import org.trailmesh.app.relevance.RelevanceContext
import org.trailmesh.app.relevance.Route

data class HikingManeuver(
    val beginIndex: Int,
    val endIndex: Int,
    val instruction: String,
    val arrival: Boolean = false,
)
data class HikingRoute(
    val points: List<MapPoint>,
    val distanceKm: Double,
    val seconds: Double,
    val maneuvers: List<HikingManeuver> = emptyList(),
) {
    fun relevance(): RelevanceContext {
        need(points.size in 2..2048, MapError.RELEVANCE_TOO_COMPLEX)
        return RelevanceContext(route = Route(points.map { GeoPoint(it.latE7, it.lonE7) }))
    }
}

object RouteParser {
    fun decodePolyline(s: String): List<MapPoint> {
        var index = 0
        var lat = 0L
        var lon = 0L
        val points = mutableListOf<MapPoint>()
        fun component(): Long {
            var value = 0L
            var shift = 0
            while (true) {
                need(index < s.length && shift <= 30, MapError.INVALID_ENGINE)
                val b = s[index++].code - 63
                need(b in 0..63, MapError.INVALID_ENGINE)
                value = value or ((b and 31).toLong() shl shift)
                if (b < 32) break
                shift += 5
            }
            return if (value and 1L != 0L) -(value shr 1) - 1 else value shr 1
        }
        while (index < s.length) {
            need(points.size < 100000, MapError.INVALID_ENGINE)
            lat += component()
            lon += component()
            need(
                lat in -90000000..90000000 && lon in -180000000..180000000,
                MapError.INVALID_ENGINE,
            )
            points.add(MapPoint(lat * 10, lon * 10))
        }
        need(points.size >= 2, MapError.INVALID_ENGINE)
        return points.toList()
    }

    fun parse(s: String, a: MapPoint, b: MapPoint): HikingRoute =
        try {
            need(s.length <= 4 * 1024 * 1024, MapError.INVALID_ENGINE)
            val o = MapJson.parse(s.toByteArray(Charsets.UTF_8), 4 * 1024 * 1024).obj()
            if (o.containsKey("error") || o.containsKey("error_code") || o.containsKey("code")) {
                val code = (o["error_code"] ?: o["code"])?.integer()
                throw engineFailure(code)
            }
            val trip = o["trip"].obj()
            need(trip["status"].integer() == 0L, MapError.NO_ROUTE)
            need(trip["units"].str() == "kilometers", MapError.INVALID_ENGINE)
            val summary = trip["summary"].obj()
            val km = summary["length"].decimal()
            val seconds = summary["time"].decimal()
            need(km >= 0 && seconds >= 0, MapError.INVALID_ENGINE)
            val legs = trip["legs"].arr()
            need(legs.size == 1, MapError.INVALID_ENGINE)
            val leg = legs.single().obj()
            val points = decodePolyline(leg["shape"].str())
            val maneuvers = leg["maneuvers"]?.arr()?.map { item ->
                val parts = item.obj()
                val from = parts["begin_shape_index"].integer()
                val to = parts["end_shape_index"].integer()
                val instruction = parts["instruction"].str().trim()
                need(from in 0L..points.lastIndex.toLong() && to in from..points.lastIndex.toLong(),
                    MapError.INVALID_ENGINE)
                need(instruction.length in 1..500, MapError.INVALID_ENGINE)
                val arrival = (parts["type"]?.integer() ?: -1L) in 4L..6L
                HikingManeuver(from.toInt(), to.toInt(), instruction, arrival)
            }.orEmpty()
            need(maneuvers.zipWithNext().all { (previous, next) -> previous.endIndex <= next.beginIndex },
                MapError.INVALID_ENGINE)
            need(
                distance(a, points.first()) <= 100 && distance(b, points.last()) <= 100,
                MapError.INVALID_ENGINE,
            )
            HikingRoute(points, km, seconds, maneuvers)
        } catch (e: MapFailure) {
            if (e.reason == MapError.CORRUPT) throw MapFailure(MapError.INVALID_ENGINE) else throw e
        } catch (_: Exception) {
            throw MapFailure(MapError.INVALID_ENGINE)
        }

    internal const val DEFAULT_HIKING_DIFFICULTY = 2

    internal fun engineFailure(code: Long?): MapFailure {
        val reason = when (code) {
            170L, 171L, 441L, 442L -> MapError.NO_ROUTE
            else -> MapError.INVALID_ENGINE
        }
        return MapFailure(reason, code)
    }

    fun request(
        a: MapPoint,
        b: MapPoint,
        bounds: BoundsE7,
        maximumHikingDifficulty: Int = DEFAULT_HIKING_DIFFICULTY,
    ): String {
        require(maximumHikingDifficulty in 0..6) { "Hiking difficulty must be between 0 and 6" }
        need(bounds.contains(a) && bounds.contains(b), MapError.OUTSIDE_COVERAGE)
        return MapJson.encode(
            mapOf(
                "locations" to
                    listOf(a, b).map {
                        mapOf(
                            "lat" to it.latE7 / 10000000.0,
                            "lon" to it.lonE7 / 10000000.0,
                            "search_cutoff" to 100,
                        )
                    },
                "costing" to "pedestrian",
                "costing_options" to
                    mapOf(
                        "pedestrian" to
                            mapOf("max_hiking_difficulty" to maximumHikingDifficulty, "use_ferry" to 0)
                    ),
                "units" to "kilometers",
                "format" to "json",
                "shape_format" to "polyline6",
            )
        )
    }

    internal fun distance(a: MapPoint, b: MapPoint): Double {
        val lat1 = Math.toRadians(a.latE7 / 10000000.0)
        val lat2 = Math.toRadians(b.latE7 / 10000000.0)
        val dlon = Math.toRadians((a.lonE7 - b.lonE7) / 10000000.0)
        val h = sin((lat1 - lat2) / 2).pow(2) + cos(lat1) * cos(lat2) * sin(dlon / 2).pow(2)
        return 6371008.8 * 2 * asin(sqrt(h.coerceIn(0.0, 1.0)))
    }
}

interface LocalRoutingEngine : Closeable {
    fun route(request: String): String
}

fun interface RoutingEngineFactory {
    fun open(graph: File): LocalRoutingEngine
}

/** Actor construction, all requests, native close and lease release share one non-main worker. */
class RegionRouter(
    private val store: RegionStore,
    private val id: String,
    private val revision: String,
    private val factory: RoutingEngineFactory,
) : Closeable {
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "trailmesh-offline-router")
    }
    private var lease: RegionLease? = null
    private var engine: LocalRoutingEngine? = null
    private var closed = false

    @Synchronized
    fun route(
        start: MapPoint,
        end: MapPoint,
        maximumHikingDifficulty: Int = RouteParser.DEFAULT_HIKING_DIFFICULTY,
    ): Future<HikingRoute> {
        if (closed)
            return CompletableFuture<HikingRoute>().apply {
                completeExceptionally(MapFailure(MapError.UNAVAILABLE))
            }
        return worker.submit<HikingRoute> {
            val l = lease ?: store.acquire(id, revision).also { lease = it }
            val request = RouteParser.request(start, end, l.region.manifest.bounds, maximumHikingDifficulty)
            try {
                val e =
                    engine
                        ?: factory.open(File(l.region.directory, "routing.tar")).also {
                            engine = it
                        }
                val result = RouteParser.parse(e.route(request), start, end)
                need(
                    result.points.all { l.region.manifest.bounds.contains(it) },
                    MapError.OUTSIDE_COVERAGE,
                )
                result
            } catch (e: MapFailure) {
                throw e
            } catch (_: Exception) {
                throw MapFailure(MapError.INVALID_ENGINE)
            }
        }
    }

    @Synchronized
    fun closeAsync(): Future<*> {
        if (closed) return CompletableFuture.completedFuture(null)
        closed = true
        val result = worker.submit {
            try {
                engine?.close()
            } finally {
                engine = null
                lease?.close()
                lease = null
            }
        }
        worker.shutdown()
        return result
    }

    override fun close() {
        closeAsync()
    }
}
