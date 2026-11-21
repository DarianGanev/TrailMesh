package org.trailmesh.app.maps

import kotlin.math.cos
import kotlin.math.hypot

internal data class RouteMatch(val shapePosition: Double, val distanceM: Double)

internal fun HikingRoute.matchPosition(fix: MapPoint): RouteMatch {
    val scaleY = 111_195.0 / 1e7
    val scaleX = scaleY * cos(Math.toRadians(fix.latE7 / 1e7))
    var bestMeters = Double.POSITIVE_INFINITY
    var bestPosition = 0.0
    for (index in 0 until points.lastIndex) {
        val a = points[index]
        val b = points[index + 1]
        val x = (a.lonE7 - fix.lonE7) * scaleX
        val y = (a.latE7 - fix.latE7) * scaleY
        val dx = (b.lonE7 - a.lonE7) * scaleX
        val dy = (b.latE7 - a.latE7) * scaleY
        val span = dx * dx + dy * dy
        val fraction = if (span == 0.0) 0.0 else (-(x * dx + y * dy) / span).coerceIn(0.0, 1.0)
        val meters = hypot(x + fraction * dx, y + fraction * dy)
        if (meters < bestMeters) {
            bestMeters = meters
            bestPosition = index + fraction
        }
    }
    return RouteMatch(bestPosition, bestMeters)
}
