package org.trailmesh.app.maps

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Looper
import android.os.SystemClock
import kotlin.math.ceil
import kotlin.math.roundToLong

internal const val FIELD_LOCATION_REQUEST = 21
private const val FRESH_LOCATION_NANOS = 30_000_000_000L

internal fun remainingLocationFixMillis(measuredAtNanos: Long, nowNanos: Long): Long {
    if (measuredAtNanos < 0 || measuredAtNanos > nowNanos) return 0
    val remaining = FRESH_LOCATION_NANOS - (nowNanos - measuredAtNanos)
    return (remaining.coerceAtLeast(0) + 999_999L) / 1_000_000L
}

internal class FieldLocation(
    private val context: Context,
    private val update: (Location) -> Unit,
) {
    private val manager = context.getSystemService(LocationManager::class.java)
    private var lastFix: Location? = null
    private var listening = false
    private val listener = object : LocationListener {
        override fun onLocationChanged(fix: Location) {
            if (listening && fresh(fix) &&
                (lastFix?.elapsedRealtimeNanos ?: Long.MIN_VALUE) <= fix.elapsedRealtimeNanos
            ) {
                lastFix = fix
                update(fix)
            }
        }

        override fun onProviderEnabled(provider: String) = Unit
        override fun onProviderDisabled(provider: String) = Unit
        @Deprecated("Required by the LocationListener interface on Android API 26–29")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit
    }

    fun hasPermission() = PERMISSIONS.any { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    fun current(): Location? = lastFix?.takeIf(::fresh)

    fun start(): Boolean {
        if (listening) return true
        if (!hasPermission()) return false
        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
        val observed = providers.filter { provider ->
            try {
                if (!manager.isProviderEnabled(provider)) return@filter false
                manager.requestLocationUpdates(provider, 1500L, 2f, listener, Looper.getMainLooper())
                true
            } catch (_: SecurityException) {
                false
            } catch (_: IllegalArgumentException) {
                false
            }
        }
        listening = observed.isNotEmpty()
        // Set listening before delivering any cached fix. A one-shot caller may stop immediately.
        val cached = observed.mapNotNull { provider ->
            try { manager.getLastKnownLocation(provider) } catch (_: SecurityException) { null }
        }.filter(::fresh).maxByOrNull { it.elapsedRealtimeNanos }
        cached?.let(listener::onLocationChanged)
        return observed.isNotEmpty()
    }

    fun stop() {
        if (listening) manager.removeUpdates(listener)
        listening = false
        lastFix = null
    }

    private fun fresh(fix: Location): Boolean {
        return fix.remainingFreshMillis() > 0 && fix.hasAccuracy() && fix.accuracy.isFinite() && fix.accuracy >= 0
    }

    companion object {
        val PERMISSIONS = arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
    }
}

internal fun Location.mapPoint() = MapPoint((latitude * 1e7).roundToLong(), (longitude * 1e7).roundToLong())
internal fun Location.reportAccuracy() = ceil(accuracy.toDouble()).toLong()
internal fun Location.remainingFreshMillis() = remainingLocationFixMillis(elapsedRealtimeNanos, SystemClock.elapsedRealtimeNanos())
