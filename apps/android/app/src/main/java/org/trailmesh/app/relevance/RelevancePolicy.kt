package org.trailmesh.app.relevance

import kotlin.math.*

/** Local E7 geometry; never part of exchange frames. Inputs are verified report projections. */
data class GeoPoint(val latE7: Long, val lonE7: Long)
data class Area(val center: GeoPoint, val radiusM: Long)
data class GPSArea(val area: Area, val accuracyM: Double, val fixAt: Long)
class Route(points: List<GeoPoint>, val corridorM: Long = 1000) {
    val points: List<GeoPoint> = java.util.Collections.unmodifiableList(points.toList())
}
data class RelevanceContext(val manualArea: Area? = null, val gpsArea: GPSArea? = null, val route: Route? = null)
data class RelevantReport(val id: String, val observedAt: Long, val expiresAt: Long, val point: GeoPoint)
enum class RelevanceDecision { eligible, notRelevant, expired, configurationRequired, invalidConfiguration }

object RelevancePolicy {
    private const val RADIUS = 6371008.8
    private const val SAFE = 9007199254740991L
    private data class V(val x: Double, val y: Double, val z: Double) {
        fun dot(b: V) = x*b.x + y*b.y + z*b.z
        fun cross(b: V) = V(y*b.z-z*b.y,z*b.x-x*b.z,x*b.y-y*b.x)
        fun norm() = sqrt(dot(this))
        fun scaled(s: Double) = V(x*s,y*s,z*s)
    }
    private fun vector(p: GeoPoint): V {
        val lat = Math.toRadians(p.latE7 / 10000000.0)
        val lon = Math.toRadians(p.lonE7 / 10000000.0)
        return V(cos(lat)*cos(lon),cos(lat)*sin(lon),sin(lat))
    }
    private fun angle(a: V,b: V) = atan2(a.cross(b).norm(),a.dot(b))
    private fun valid(p: GeoPoint) = p.latE7 in -900000000L..900000000L && p.lonE7 in -1800000000L..1800000000L
    private fun valid(a: Area) = valid(a.center) && a.radiusM in 100L..50000L
    private fun valid(c: RelevanceContext): Boolean =
        (c.manualArea?.let { valid(it) } ?: true) &&
        (c.gpsArea?.let { valid(it.area) && it.accuracyM.isFinite() && it.accuracyM in 0.0..SAFE.toDouble() && it.fixAt in 0..SAFE } ?: true) &&
        (c.route?.let { r -> r.corridorM in 100L..10000L && r.points.size in 1..2048 && r.points.all { valid(it) } && r.points.zipWithNext().all { (a,b) -> vector(a).dot(vector(b)) > -1+1e-12 } } ?: true)

    /** Closed minor arc, including repeated vertices, poles and antimeridian crossings. */
    private fun segment(p: V,a: V,b: V): Double {
        val cross = a.cross(b)
        val length = cross.norm()
        if (length < 1e-15) return RADIUS*angle(p,a)
        val normal = cross.scaled(1/length)
        val tangent = normal.cross(a)
        val along = atan2(p.dot(tangent),p.dot(a))
        if (along >= 0 && along <= atan2(length,a.dot(b)))
            return RADIUS*atan2(abs(p.dot(normal)),hypot(p.dot(a),p.dot(tangent)))
        return RADIUS*min(angle(p,a),angle(p,b))
    }
    fun evaluate(report: RelevantReport, context: RelevanceContext?, now: Long): RelevanceDecision {
        if (now !in 0..SAFE || (context != null && !valid(context))) return RelevanceDecision.invalidConfiguration
        if (report.expiresAt <= now) return RelevanceDecision.expired
        val areas = buildList {
            context?.manualArea?.let { add(it) }
            context?.gpsArea?.let { if (it.accuracyM <= 1000 && now-it.fixAt in 0..300000) add(it.area) }
        }
        val route = context?.route
        if (areas.isEmpty() && route == null) return RelevanceDecision.configurationRequired
        val point = vector(report.point)
        if (areas.any { RADIUS*angle(point,vector(it.center)) <= it.radiusM+0.000001 }) return RelevanceDecision.eligible
        if (route != null) {
            val points = route.points.map { vector(it) }
            if ((if (points.size == 1) listOf(points[0] to points[0]) else points.zipWithNext()).any { (a,b) -> segment(point,a,b) <= route.corridorM+0.000001 }) return RelevanceDecision.eligible
        }
        return RelevanceDecision.notRelevant
    }
    /** Local display ordering only. Exchange inventories must keep ID ascending order. */
    fun select(reports: List<RelevantReport>, context: RelevanceContext?, now: Long): List<RelevantReport> =
        reports.sortedWith(compareByDescending<RelevantReport> { it.observedAt }.thenBy { it.id })
            .filter { evaluate(it,context,now) == RelevanceDecision.eligible }.distinctBy { it.id }

    /** Strict local settings boundary; malformed values produce a typed decision, no diagnostics. */
    fun evaluateLocal(report: RelevantReport, value: Any?, now: Long): RelevanceDecision =
        try { evaluate(report,parseLocal(value),now) } catch (_: IllegalArgumentException) { RelevanceDecision.invalidConfiguration }

    fun parseLocal(value: Any?): RelevanceContext? {
        if (value == null) return null
        fun obj(v: Any?, allowed: Set<String>, required: Set<String> = allowed): Map<*,*> {
            require(v is Map<*,*> && v.keys.all { it in allowed } && v.keys.containsAll(required))
            return v
        }
        fun integer(v: Any?): Long { require(v is Int || v is Long); return (v as Number).toLong() }
        fun point(v: Any?): GeoPoint {
            val o = obj(v,setOf("lat_e7","lon_e7"))
            return GeoPoint(integer(o["lat_e7"]),integer(o["lon_e7"]))
        }
        fun area(v: Any?, gps: Boolean = false): Area {
            val keys = if (gps) setOf("center","radius_m","accuracy_m","fix_at_ms") else setOf("center","radius_m")
            val o = obj(v,keys)
            return Area(point(o["center"]),integer(o["radius_m"]))
        }
        val c = obj(value,setOf("manual_area","gps_area","route"),emptySet())
        val manual = if (c.containsKey("manual_area")) area(c["manual_area"]) else null
        val gps = if (c.containsKey("gps_area")) {
            val a = area(c["gps_area"],true)
            val o = c["gps_area"] as Map<*,*>
            val accuracy = o["accuracy_m"]
            require(accuracy is Int || accuracy is Long || accuracy is Double || accuracy is Float)
            GPSArea(a,(accuracy as Number).toDouble(),integer(o["fix_at_ms"]))
        } else null
        val route = if (c.containsKey("route")) {
            val o = obj(c["route"],setOf("points","corridor_m"),setOf("points"))
            val points = o["points"]
            require(points is List<*>)
            Route(points.map { point(it) },if (o.containsKey("corridor_m")) integer(o["corridor_m"]) else 1000)
        } else null
        return RelevanceContext(manual,gps,route).also { require(valid(it)) }
    }
}
